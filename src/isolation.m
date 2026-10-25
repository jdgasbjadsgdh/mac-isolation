/* Per-profile Steam compatibility layer. Cooperative isolation, with a separate
 * kernel sandbox guarding the host Steam files/service. Does not alter UID or
 * system security. Loaded only into prepared copies and native test fixtures. */
#define _DARWIN_C_SOURCE
#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <servers/bootstrap.h>
#include <mach/mach.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/mman.h>
#include <spawn.h>
#include <pwd.h>
#include <libproc.h>
#include <signal.h>
#include <dirent.h>
#include <dlfcn.h>
#include <semaphore.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <objc/runtime.h>
#include <objc/message.h>

#ifndef INTERPOSE
#define INTERPOSE(new,old) __attribute__((used)) static const struct {const void *replacement,*original;} ip_##old __attribute__((section("__DATA,__interpose")))={(const void*)(uintptr_t)&new,(const void*)(uintptr_t)&old}
#endif
static int ready;
static char private_home[PATH_MAX], primary_home[PATH_MAX], steam_source[PATH_MAX], steam_private[PATH_MAX];
static char app_source[PATH_MAX], app_private[PATH_MAX], ipc_root[PATH_MAX], namespace_id[33], ipc_namespace[33], mach_service[128];
/* Sandboxed processes cannot execute setuid binaries, so /bin/ps fails with
   EPERM. Steam needs it to accept its own web UI connection; the bundled
   non-setuid msi-ps beside this library answers the same queries. */
static char ps_tool[PATH_MAX], ps_tool_quoted[4*PATH_MAX+3];
static const char *original_service="com.valvesoftware.steam.ipctool";
static const char *environment_keys[]={"HOME","CFFIXED_USER_HOME","TMPDIR","DYLD_INSERT_LIBRARIES","MSI_ISOLATION_LIBRARY","MSI_PRIVATE_HOME","MSI_PRIMARY_HOME","MSI_STEAM_SOURCE","MSI_STEAM_PRIVATE","MSI_APP_SOURCE","MSI_APP_PRIVATE","MSI_IPC_ROOT","MSI_NAMESPACE","MSI_IPC_NAMESPACE","MSI_TRACE",NULL};
static char *preserved_environment[sizeof(environment_keys)/sizeof(*environment_keys)];
static int prefix(const char *s,const char *p){size_t n=strlen(p);return n&&strncmp(s,p,n)==0&&(s[n]==0||s[n]=='/');}
static uint64_t hash_name(const char *s){uint64_t n=14695981039346656037ULL;for(;*s;s++){n^=(unsigned char)*s;n*=1099511628211ULL;}return n;}
static int copy_environment(const char *key,char *out,size_t length){const char *s=getenv(key);if(!s||!*s||strlen(s)>=length)return 0;strcpy(out,s);return 1;}
static void shell_quote_into(char *out,const char *value){
    *out++='\'';for(;*value;value++){if(*value=='\''){memcpy(out,"'\\''",4);out+=4;}else *out++=*value;}*out++='\'';*out=0;
}
static void find_ps_tool(void){
    const char *library=getenv("MSI_ISOLATION_LIBRARY"),*slash=library?strrchr(library,'/'):NULL;
    if(!slash||slash==library)return;
    int n=snprintf(ps_tool,sizeof(ps_tool),"%.*s/msi-ps",(int)(slash-library),library);
    if(n<0||n>=(int)sizeof(ps_tool)||access(ps_tool,X_OK)){ps_tool[0]=0;return;}
    shell_quote_into(ps_tool_quoted,ps_tool);
}
/* Each Steam brings itself forward whenever a Steam web helper (by bundle ID)
   becomes active. With two clients open they followed each other's helpers
   about 100 times a second and froze the Mac. Inside a private client, apps of
   another Steam report a foreign ID and cannot be activated; this profile's
   renamed main app reports Valve's ID, so the client still follows its own. */
static NSString *private_main_id;
static IMP original_bundle_identifier,original_activate,original_activate_from,original_running_with_identifier;
static pid_t app_pid(id app){return ((pid_t(*)(id,SEL))objc_msgSend)(app,sel_registerName("processIdentifier"));}
static int own_app(pid_t pid,int *main_app){
    char path[PROC_PIDPATHINFO_MAXSIZE];if(proc_pidpath(pid,path,sizeof(path))<=0||!prefix(path,app_private))return 0;
    if(main_app){char main_path[PATH_MAX];snprintf(main_path,sizeof(main_path),"%s/Contents/MacOS/steam_osx",app_private);*main_app=!strcmp(path,main_path);}
    return 1;
}
static int steam_identity(NSString *value){
    return [value hasPrefix:@"com.valvesoftware."]||[value hasPrefix:@"com.macsteam.isolation."];
}
static NSString *raw_bundle_identifier(id app){return ((NSString*(*)(id,SEL))original_bundle_identifier)(app,sel_registerName("bundleIdentifier"));}
static NSString *isolated_bundle_identifier(id self,SEL _cmd){
    NSString *value=((NSString*(*)(id,SEL))original_bundle_identifier)(self,_cmd);int main_app=0;
    if(value&&!steam_identity(value))return value;
    if(own_app(app_pid(self),&main_app)){
        return main_app?@"com.valvesoftware.steam":value;
    }
    return value?[@"com.macsteam.isolation.foreign." stringByAppendingString:value]:nil;
}
static int foreign_steam(id app){NSString *value=raw_bundle_identifier(app);return value&&steam_identity(value)&&!own_app(app_pid(app),NULL);}
static BOOL isolated_activate(id self,SEL _cmd,NSUInteger options){
    if(foreign_steam(self))return NO;
    return ((BOOL(*)(id,SEL,NSUInteger))original_activate)(self,_cmd,options);
}
static BOOL isolated_activate_from(id self,SEL _cmd,id from,NSUInteger options){
    if(foreign_steam(self))return NO;
    return ((BOOL(*)(id,SEL,id,NSUInteger))original_activate_from)(self,_cmd,from,options);
}
static NSArray *isolated_running_with_identifier(id self,SEL _cmd,NSString *identifier){
    NSArray *result=((NSArray*(*)(id,SEL,NSString*))original_running_with_identifier)(self,_cmd,identifier);
    if(!identifier||!steam_identity(identifier))return result;
    NSString *alias=[identifier isEqualToString:@"com.valvesoftware.steam"]?private_main_id:nil;
    if(alias)result=[result arrayByAddingObjectsFromArray:((NSArray*(*)(id,SEL,NSString*))original_running_with_identifier)(self,_cmd,alias)];
    NSMutableArray *own=[NSMutableArray array];
    for(id app in result)if(own_app(app_pid(app),NULL)&&![own containsObject:app])[own addObject:app];
    return own;
}
/* The actual focus loop: Steam's main app and web helper signal each other
   with session-wide distributed notifications (com.valvesoftware.steam.
   ActivateSteam, ActivateWebhelper, HideSteam ...). Every Steam on the Mac
   obeyed the other's, so they kept activating each other. A private client
   posts and observes these under its own profile's name instead. */
static NSString *notification_prefix;
static IMP original_post_deliver,original_post_options,original_post_info,original_post,original_post_notification;
static IMP original_observe_block,original_observe,original_observe_suspension,original_remove;
static NSString *private_name(NSString *name){
    return [name hasPrefix:@"com.valvesoftware."]?[notification_prefix stringByAppendingString:[name substringFromIndex:18]]:name;
}
static void isolated_post_deliver(id self,SEL _cmd,NSString *name,NSString *object,NSDictionary *info,BOOL immediately){
    ((void(*)(id,SEL,NSString*,NSString*,NSDictionary*,BOOL))original_post_deliver)(self,_cmd,private_name(name),object,info,immediately);
}
static void isolated_post_options(id self,SEL _cmd,NSString *name,NSString *object,NSDictionary *info,NSUInteger options){
    ((void(*)(id,SEL,NSString*,NSString*,NSDictionary*,NSUInteger))original_post_options)(self,_cmd,private_name(name),object,info,options);
}
static void isolated_post_info(id self,SEL _cmd,NSString *name,NSString *object,NSDictionary *info){
    ((void(*)(id,SEL,NSString*,NSString*,NSDictionary*))original_post_info)(self,_cmd,private_name(name),object,info);
}
static void isolated_post(id self,SEL _cmd,NSString *name,NSString *object){
    ((void(*)(id,SEL,NSString*,NSString*))original_post)(self,_cmd,private_name(name),object);
}
static void isolated_post_notification(id self,SEL _cmd,NSNotification *notification){
    NSString *name=private_name(notification.name);
    if(name!=notification.name)notification=[NSNotification notificationWithName:name object:notification.object userInfo:notification.userInfo];
    ((void(*)(id,SEL,NSNotification*))original_post_notification)(self,_cmd,notification);
}
static id isolated_observe_block(id self,SEL _cmd,NSString *name,NSString *object,NSOperationQueue *queue,void (^block)(NSNotification*)){
    return ((id(*)(id,SEL,NSString*,NSString*,NSOperationQueue*,void(^)(NSNotification*)))original_observe_block)(self,_cmd,private_name(name),object,queue,block);
}
static void isolated_observe(id self,SEL _cmd,id observer,SEL selector,NSString *name,NSString *object){
    ((void(*)(id,SEL,id,SEL,NSString*,NSString*))original_observe)(self,_cmd,observer,selector,private_name(name),object);
}
static void isolated_observe_suspension(id self,SEL _cmd,id observer,SEL selector,NSString *name,NSString *object,NSUInteger behavior){
    ((void(*)(id,SEL,id,SEL,NSString*,NSString*,NSUInteger))original_observe_suspension)(self,_cmd,observer,selector,private_name(name),object,behavior);
}
static void isolated_remove(id self,SEL _cmd,id observer,NSString *name,NSString *object){
    ((void(*)(id,SEL,id,NSString*,NSString*))original_remove)(self,_cmd,observer,private_name(name),object);
}
/* Replace only a method the class defines itself, never an inherited one, so
   ordinary NSNotificationCenter traffic is untouched. */
static void swap_own_method(Class class,const char *name,IMP replacement,IMP *original){
    SEL selector=sel_registerName(name);unsigned count=0;Method *methods=class_copyMethodList(class,&count);
    for(unsigned i=0;i<count;i++)if(method_getName(methods[i])==selector){*original=method_setImplementation(methods[i],replacement);break;}
    free(methods);
}
static void install_notification_filter(void){
    Class center=objc_getClass("NSDistributedNotificationCenter");if(!center)return;
    notification_prefix=[NSString stringWithFormat:@"com.macsteam.isolation.%s.",namespace_id];
    swap_own_method(center,"postNotificationName:object:userInfo:deliverImmediately:",(IMP)isolated_post_deliver,&original_post_deliver);
    swap_own_method(center,"postNotificationName:object:userInfo:options:",(IMP)isolated_post_options,&original_post_options);
    swap_own_method(center,"postNotificationName:object:userInfo:",(IMP)isolated_post_info,&original_post_info);
    swap_own_method(center,"postNotificationName:object:",(IMP)isolated_post,&original_post);
    swap_own_method(center,"postNotification:",(IMP)isolated_post_notification,&original_post_notification);
    swap_own_method(center,"addObserverForName:object:queue:usingBlock:",(IMP)isolated_observe_block,&original_observe_block);
    swap_own_method(center,"addObserver:selector:name:object:",(IMP)isolated_observe,&original_observe);
    swap_own_method(center,"addObserver:selector:name:object:suspensionBehavior:",(IMP)isolated_observe_suspension,&original_observe_suspension);
    swap_own_method(center,"removeObserver:name:object:",(IMP)isolated_remove,&original_remove);
}
static void swap_method(Class class,BOOL meta,const char *name,IMP replacement,IMP *original){
    Method method=meta?class_getClassMethod(class,sel_registerName(name)):class_getInstanceMethod(class,sel_registerName(name));
    if(method)*original=method_setImplementation(method,replacement);
}
static void install_activation_filter(void){
    private_main_id=[NSString stringWithFormat:@"com.macsteam.isolation.%s.steam",namespace_id];
    Class running=objc_getClass("NSRunningApplication");if(!running)return;
    swap_method(running,NO,"bundleIdentifier",(IMP)isolated_bundle_identifier,&original_bundle_identifier);
    if(!original_bundle_identifier)return;
    swap_method(running,NO,"activateWithOptions:",(IMP)isolated_activate,&original_activate);
    swap_method(running,NO,"activateFromApplication:options:",(IMP)isolated_activate_from,&original_activate_from);
    swap_method(running,YES,"runningApplicationsWithBundleIdentifier:",(IMP)isolated_running_with_identifier,&original_running_with_identifier);
}

__attribute__((constructor)) static void initialize(void){
    if(!copy_environment("MSI_PRIVATE_HOME",private_home,sizeof(private_home))||
       !copy_environment("MSI_PRIMARY_HOME",primary_home,sizeof(primary_home))||
       !copy_environment("MSI_STEAM_SOURCE",steam_source,sizeof(steam_source))||
       !copy_environment("MSI_STEAM_PRIVATE",steam_private,sizeof(steam_private))||
       !copy_environment("MSI_APP_SOURCE",app_source,sizeof(app_source))||
       !copy_environment("MSI_APP_PRIVATE",app_private,sizeof(app_private))||
       !copy_environment("MSI_IPC_ROOT",ipc_root,sizeof(ipc_root))||
       !copy_environment("MSI_NAMESPACE",namespace_id,sizeof(namespace_id)))_exit(125);
    if(strlen(namespace_id)!=32||strspn(namespace_id,"0123456789abcdef")!=32||
       !strcmp(primary_home,private_home)||!strcmp(steam_source,steam_private)||
       !strcmp(app_source,app_private)||private_home[0]!='/'||ipc_root[0]!='/')_exit(125);
    /* POSIX semaphores outlive killed processes. A fresh name space for each
       Steam launch keeps a new client from reopening a previous session's
       locked mutex; older profiles without one keep using the profile id. */
    if(!copy_environment("MSI_IPC_NAMESPACE",ipc_namespace,sizeof(ipc_namespace)))strcpy(ipc_namespace,namespace_id);
    if(strlen(ipc_namespace)!=32||strspn(ipc_namespace,"0123456789abcdef")!=32)_exit(125);
    find_ps_tool();
    snprintf(mach_service,sizeof(mach_service),"com.macsteam.isolation.%s.ipctool",namespace_id);
    for(unsigned i=0;environment_keys[i];i++){const char *value=getenv(environment_keys[i]);if(value){preserved_environment[i]=strdup(value);if(!preserved_environment[i])_exit(125);}}
    ready=1;
    install_notification_filter();
    install_activation_filter();
}
static const char *map_path(const char *path,char buffer[PATH_MAX]){
    if(!ready||!path||path[0]!='/')return path;
    const char *unchanged=path;char canonical[PATH_MAX];
    if(!strncmp(path,"/var/",5)||!strncmp(path,"/tmp/",5)||!strncmp(path,"/etc/",5)){
        int n=snprintf(canonical,sizeof(canonical),"/private%s",path);
        if(n<0||n>=PATH_MAX){errno=ENAMETOOLONG;return NULL;}path=canonical;
    }
    const char *from=NULL,*to=NULL;
    if(prefix(path,steam_source)){from=steam_source;to=steam_private;}
    else if(prefix(path,app_source)){from=app_source;to=app_private;}
    else{
        char legacy[PATH_MAX];snprintf(legacy,sizeof(legacy),"%s/.steam",primary_home);
        if(prefix(path,legacy)){
            int n=snprintf(buffer,PATH_MAX,"%s/.steam%s",private_home,path+strlen(legacy));
            if(n<0||n>=PATH_MAX){errno=ENAMETOOLONG;return NULL;}return buffer;
        }
        const char *temporary=path;
        if(!strncmp(path,"/private/tmp/",13))temporary=path+8;
        if(!strncmp(temporary,"/tmp/steam",10)){
            int n=snprintf(buffer,PATH_MAX,"%s/f-%016llx",ipc_root,(unsigned long long)hash_name(temporary));
            if(n<0||n>=PATH_MAX){errno=ENAMETOOLONG;return NULL;}return buffer;
        }
        return unchanged;
    }
    int n=snprintf(buffer,PATH_MAX,"%s%s",to,path+strlen(from));
    if(n<0||n>=PATH_MAX){errno=ENAMETOOLONG;return NULL;}return buffer;
}
static int isolated_open(const char *path,int flags,...){
    mode_t mode=0;if(flags&O_CREAT){va_list args;va_start(args,flags);mode=(mode_t)va_arg(args,int);va_end(args);}
    char b[PATH_MAX];const char *p=map_path(path,b);if(!p)return -1;return open(p,flags,mode);
} INTERPOSE(isolated_open,open);
static int isolated_openat(int fd,const char *path,int flags,...){
    mode_t mode=0;if(flags&O_CREAT){va_list args;va_start(args,flags);mode=(mode_t)va_arg(args,int);va_end(args);}
    char b[PATH_MAX];const char *p=map_path(path,b);if(!p)return -1;return openat(fd,p,flags,mode);
} INTERPOSE(isolated_openat,openat);
static FILE *isolated_fopen(const char *path,const char *mode){char b[PATH_MAX];const char *p=map_path(path,b);return p?fopen(p,mode):NULL;} INTERPOSE(isolated_fopen,fopen);
static int isolated_access(const char *path,int mode){char b[PATH_MAX];const char *p=map_path(path,b);return p?access(p,mode):-1;} INTERPOSE(isolated_access,access);
static int isolated_stat(const char *path,struct stat *out){char b[PATH_MAX];const char *p=map_path(path,b);return p?stat(p,out):-1;} INTERPOSE(isolated_stat,stat);
static int isolated_lstat(const char *path,struct stat *out){char b[PATH_MAX];const char *p=map_path(path,b);return p?lstat(p,out):-1;} INTERPOSE(isolated_lstat,lstat);
static int isolated_mkdir(const char *path,mode_t mode){char b[PATH_MAX];const char *p=map_path(path,b);return p?mkdir(p,mode):-1;} INTERPOSE(isolated_mkdir,mkdir);
static int isolated_mkfifo(const char *path,mode_t mode){char b[PATH_MAX];const char *p=map_path(path,b);return p?mkfifo(p,mode):-1;} INTERPOSE(isolated_mkfifo,mkfifo);
static void *isolated_dlopen(const char *path,int flags){char b[PATH_MAX];const char *p=map_path(path,b);return p?dlopen(p,flags):NULL;} INTERPOSE(isolated_dlopen,dlopen);
static int isolated_unlink(const char *path){char b[PATH_MAX];const char *p=map_path(path,b);return p?unlink(p):-1;} INTERPOSE(isolated_unlink,unlink);
static int isolated_rename(const char *from,const char *to){char a[PATH_MAX],b[PATH_MAX];const char *f=map_path(from,a),*t=map_path(to,b);return f&&t?rename(f,t):-1;} INTERPOSE(isolated_rename,rename);
static int isolated_chdir(const char *path){char b[PATH_MAX];const char *p=map_path(path,b);return p?chdir(p):-1;} INTERPOSE(isolated_chdir,chdir);
static DIR *isolated_opendir(const char *path){char b[PATH_MAX];const char *p=map_path(path,b);return p?opendir(p):NULL;} INTERPOSE(isolated_opendir,opendir);
static char *isolated_realpath(const char *path,char *out){char b[PATH_MAX];const char *p=map_path(path,b);return p?realpath(p,out):NULL;} INTERPOSE(isolated_realpath,realpath);
static ssize_t isolated_readlink(const char *path,char *out,size_t length){char b[PATH_MAX];const char *p=map_path(path,b);return p?readlink(p,out,length):-1;} INTERPOSE(isolated_readlink,readlink);

static struct passwd *isolated_getpwuid(uid_t uid){
    struct passwd *p=getpwuid(uid);if(!ready||!p||uid!=getuid())return p;
    static _Thread_local struct passwd copy;copy=*p;copy.pw_dir=private_home;return &copy;
} INTERPOSE(isolated_getpwuid,getpwuid);
static int isolated_getpwuid_r(uid_t uid,struct passwd *p,char *buffer,size_t size,struct passwd **result){
    int status=getpwuid_r(uid,p,buffer,size,result);if(!ready||status||!*result||uid!=getuid())return status;
    char *end=buffer;const char *fields[]={p->pw_name,p->pw_passwd,p->pw_class,p->pw_gecos,p->pw_dir,p->pw_shell};
    for(unsigned i=0;i<sizeof(fields)/sizeof(*fields);i++)if(fields[i]&&fields[i]>=buffer&&fields[i]<buffer+size){char *last=(char*)fields[i]+strlen(fields[i])+1;if(last>end)end=last;}
    size_t length=strlen(private_home)+1;if(length>size-(size_t)(end-buffer)){*result=NULL;return ERANGE;}
    memcpy(end,private_home,length);p->pw_dir=end;return 0;
} INTERPOSE(isolated_getpwuid_r,getpwuid_r);
static NSString *isolated_NSHomeDirectory(void){return ready?[NSString stringWithUTF8String:private_home]:NSHomeDirectory();} INTERPOSE(isolated_NSHomeDirectory,NSHomeDirectory);
static NSString *isolated_NSTemporaryDirectory(void){return ready?[[NSString stringWithUTF8String:ipc_root] stringByAppendingString:@"/"]:NSTemporaryDirectory();} INTERPOSE(isolated_NSTemporaryDirectory,NSTemporaryDirectory);

static int preference_path(CFStringRef application,char path[PATH_MAX]){
    if(!ready)return 0;
    char original[512];
    int current=application&&CFEqual(application,kCFPreferencesCurrentApplication);
    if(!current&&(!application||!CFStringGetCString(application,original,sizeof(original),kCFStringEncodingUTF8)))return 0;
    if(!current&&strncmp(original,"com.valvesoftware.",18)&&strncmp(original,"com.valve.",10)&&strncmp(original,"com.macsteam.isolation.",22))return 0;
    int n=snprintf(path,PATH_MAX,"%s/Library/Preferences/steam-%016llx.plist",private_home,(unsigned long long)hash_name(current?"Steam":original));
    return n>0&&n<PATH_MAX;
}
static CFMutableDictionaryRef preference_read(const char *path){
    CFMutableDictionaryRef dict=NULL;int fd=open(path,O_RDONLY|O_CLOEXEC);
    if(fd>=0){struct stat status={0};if(!fstat(fd,&status)&&status.st_size>0&&status.st_size<=16*1024*1024){
        size_t size=(size_t)status.st_size,used=0;uint8_t *bytes=malloc(size);
        if(bytes){while(used<size){ssize_t count=read(fd,bytes+used,size-used);if(count<0&&errno==EINTR)continue;if(count<=0)break;used+=(size_t)count;}
            if(used==size){CFDataRef data=CFDataCreate(NULL,bytes,(CFIndex)size);if(data){CFPropertyListRef value=CFPropertyListCreateWithData(NULL,data,kCFPropertyListMutableContainers,NULL,NULL);CFRelease(data);
                if(value&&CFGetTypeID(value)==CFDictionaryGetTypeID())dict=(CFMutableDictionaryRef)value;else if(value)CFRelease(value);}}
            free(bytes);}}
        close(fd);}
    return dict?dict:CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
static Boolean preference_write(const char *path,CFStringRef key,CFPropertyListRef value,CFDictionaryRef multiple,CFArrayRef remove){
    char lockpath[PATH_MAX];if(snprintf(lockpath,sizeof(lockpath),"%s.lock",path)>=(int)sizeof(lockpath))return false;
    int lock=open(lockpath,O_RDWR|O_CREAT|O_CLOEXEC,0600);if(lock<0)return false;
    if(flock(lock,LOCK_EX)){close(lock);return false;}CFMutableDictionaryRef dict=preference_read(path);
    if(key){if(value)CFDictionarySetValue(dict,key,value);else CFDictionaryRemoveValue(dict,key);}
    if(multiple){CFIndex count=CFDictionaryGetCount(multiple);const void **keys=calloc((size_t)count,sizeof(void*)),**values=calloc((size_t)count,sizeof(void*));
        if(keys&&values){CFDictionaryGetKeysAndValues(multiple,keys,values);for(CFIndex i=0;i<count;i++)CFDictionarySetValue(dict,keys[i],values[i]);}free(keys);free(values);}
    if(remove)for(CFIndex i=0;i<CFArrayGetCount(remove);i++)CFDictionaryRemoveValue(dict,CFArrayGetValueAtIndex(remove,i));
    CFDataRef data=CFPropertyListCreateData(NULL,dict,kCFPropertyListBinaryFormat_v1_0,0,NULL);CFRelease(dict);
    Boolean success=false;char temporary[PATH_MAX];
    if(data&&snprintf(temporary,sizeof(temporary),"%s.tmp.XXXXXX",path)<(int)sizeof(temporary)){
        int fd=mkstemp(temporary);if(fd>=0){fchmod(fd,0600);CFIndex length=CFDataGetLength(data),used=0;const uint8_t *bytes=CFDataGetBytePtr(data);
            while(used<length){ssize_t count=write(fd,bytes+used,(size_t)(length-used));if(count<0&&errno==EINTR)continue;if(count<=0)break;used+=count;}
            success=used==length&&!fsync(fd);close(fd);if(success)success=rename(temporary,path)==0;if(!success)unlink(temporary);}}
    if(data)CFRelease(data);flock(lock,LOCK_UN);close(lock);return success;
}
static CFPropertyListRef preference_copy(const char *path,CFStringRef key){CFMutableDictionaryRef dict=preference_read(path);CFPropertyListRef value=key?CFDictionaryGetValue(dict,key):NULL;if(value)CFRetain(value);CFRelease(dict);return value;}
static CFPropertyListRef isolated_pref_copy(CFStringRef key,CFStringRef app){
    char path[PATH_MAX];if(!preference_path(app,path))return CFPreferencesCopyAppValue(key,app);
    CFPropertyListRef value=preference_copy(path,key);
    if(!value){snprintf(path,sizeof(path),"%s/Library/Preferences/.GlobalPreferences.plist",private_home);value=preference_copy(path,key);}
    return value;
} INTERPOSE(isolated_pref_copy,CFPreferencesCopyAppValue);
static void isolated_pref_set(CFStringRef key,CFPropertyListRef value,CFStringRef app){char path[PATH_MAX];if(preference_path(app,path))preference_write(path,key,value,NULL,NULL);else CFPreferencesSetAppValue(key,value,app);} INTERPOSE(isolated_pref_set,CFPreferencesSetAppValue);
static Boolean isolated_pref_sync(CFStringRef app){char path[PATH_MAX];return preference_path(app,path)?true:CFPreferencesAppSynchronize(app);} INTERPOSE(isolated_pref_sync,CFPreferencesAppSynchronize);
static CFPropertyListRef isolated_pref_copy_value(CFStringRef key,CFStringRef app,CFStringRef user,CFStringRef host){char path[PATH_MAX];return preference_path(app,path)?preference_copy(path,key):CFPreferencesCopyValue(key,app,user,host);} INTERPOSE(isolated_pref_copy_value,CFPreferencesCopyValue);
static void isolated_pref_set_value(CFStringRef key,CFPropertyListRef value,CFStringRef app,CFStringRef user,CFStringRef host){char path[PATH_MAX];if(preference_path(app,path))preference_write(path,key,value,NULL,NULL);else CFPreferencesSetValue(key,value,app,user,host);} INTERPOSE(isolated_pref_set_value,CFPreferencesSetValue);
static Boolean isolated_pref_synchronize(CFStringRef app,CFStringRef user,CFStringRef host){char path[PATH_MAX];return preference_path(app,path)?true:CFPreferencesSynchronize(app,user,host);} INTERPOSE(isolated_pref_synchronize,CFPreferencesSynchronize);
static CFDictionaryRef isolated_pref_multiple(CFArrayRef keys,CFStringRef app,CFStringRef user,CFStringRef host){
    char path[PATH_MAX];if(!preference_path(app,path))return CFPreferencesCopyMultiple(keys,app,user,host);CFMutableDictionaryRef dict=preference_read(path);if(!keys)return dict;
    CFMutableDictionaryRef selected=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    for(CFIndex i=0;i<CFArrayGetCount(keys);i++){const void *key=CFArrayGetValueAtIndex(keys,i),*value=CFDictionaryGetValue(dict,key);if(value)CFDictionarySetValue(selected,key,value);}CFRelease(dict);return selected;
} INTERPOSE(isolated_pref_multiple,CFPreferencesCopyMultiple);
static void isolated_pref_set_multiple(CFDictionaryRef values,CFArrayRef remove,CFStringRef app,CFStringRef user,CFStringRef host){char path[PATH_MAX];if(preference_path(app,path))preference_write(path,NULL,NULL,values,remove);else CFPreferencesSetMultiple(values,remove,app,user,host);} INTERPOSE(isolated_pref_set_multiple,CFPreferencesSetMultiple);

static const char *service_name(const char *name){return ready&&name&&!strcmp(name,original_service)?mach_service:name;}
static kern_return_t isolated_lookup(mach_port_t port,const char *name,mach_port_t *service){return bootstrap_look_up(port,service_name(name),service);} INTERPOSE(isolated_lookup,bootstrap_look_up);
static kern_return_t isolated_checkin(mach_port_t port,const char *name,mach_port_t *service){return bootstrap_check_in(port,service_name(name),service);} INTERPOSE(isolated_checkin,bootstrap_check_in);
static const char *ipc_name(const char *name,char out[32]){
    if(!ready||!name)return name;
    /* Foundation must still reach the OS notification/preferences daemons. */
    const char *base=name[0]=='/'?name+1:name;
    if(!strncmp(base,"apple.",6)||!strncmp(base,"com.apple.",10))return name;
    snprintf(out,32,"/ms2_%.10s_%012llx",ipc_namespace,(unsigned long long)(hash_name(name)&0xffffffffffffULL));return out;
}
/* Record every name created in this launch's name space, so the manager can
   unlink what a killed session leaves in the kernel. One short O_APPEND write
   per line keeps concurrent writers from interleaving. */
static void record_ipc_name(char kind,const char *mapped){
    int saved=errno;char path[PATH_MAX],line[48];
    if(snprintf(path,sizeof(path),"%s/ipc-%.10s.names",ipc_root,ipc_namespace)<(int)sizeof(path)){
        int fd=open(path,O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC|O_NOFOLLOW,0600);
        if(fd>=0){int n=snprintf(line,sizeof(line),"%c %s\n",kind,mapped);if(n>0&&n<(int)sizeof(line)&&write(fd,line,(size_t)n)<0){}close(fd);}
    }
    errno=saved;
}
static sem_t *isolated_sem_open(const char *name,int flags,...){
    mode_t mode=0;unsigned value=0;if(flags&O_CREAT){va_list args;va_start(args,flags);mode=(mode_t)va_arg(args,int);value=va_arg(args,unsigned);va_end(args);}
    char b[32];const char *mapped=ipc_name(name,b);sem_t *result=sem_open(mapped,flags,mode,value);
    if(ready&&result!=SEM_FAILED&&(flags&O_CREAT)&&mapped==b)record_ipc_name('s',mapped);
    if(ready&&getenv("MSI_IPC_TRACE")){int saved=errno;fprintf(stderr,"[MacSteam IPC %d] sem_open flags=%x mode=%o initial=%u logical=%s mapped=%s success=%d errno=%d\n",getpid(),flags,mode,value,name?name:"(null)",mapped?mapped:"(null)",result!=SEM_FAILED,result==SEM_FAILED?saved:0);errno=saved;}
    return result;
} INTERPOSE(isolated_sem_open,sem_open);
static int isolated_sem_unlink(const char *name){char b[32];return sem_unlink(ipc_name(name,b));} INTERPOSE(isolated_sem_unlink,sem_unlink);
static int isolated_shm_open(const char *name,int flags,...){
    /* Darwin declares shm_open variadic. arm64 places this mode on the stack,
       unlike a fixed third parameter; reading a register can create mode-0 IPC. */
    mode_t mode=0;if(flags&O_CREAT){va_list args;va_start(args,flags);mode=(mode_t)va_arg(args,int);va_end(args);}
    char b[32];const char *mapped=ipc_name(name,b);int result=shm_open(mapped,flags,mode);
    if(ready&&result>=0&&(flags&O_CREAT)&&mapped==b)record_ipc_name('m',mapped);
    if(result<0&&getenv("MSI_TRACE")){int saved=errno;fprintf(stderr,"[MacSteam] shm_open failed: flags=%x errno=%d name=%s\n",flags,saved,name?name:"(null)");errno=saved;}return result;
} INTERPOSE(isolated_shm_open,shm_open);
static int isolated_shm_unlink(const char *name){char b[32];return shm_unlink(ipc_name(name,b));} INTERPOSE(isolated_shm_unlink,shm_unlink);
static int isolated_ftruncate(int fd,off_t length){int result=ftruncate(fd,length);if(result<0&&getenv("MSI_TRACE")){int saved=errno;fprintf(stderr,"[MacSteam] ftruncate failed: fd=%d length=%lld errno=%d\n",fd,(long long)length,saved);errno=saved;}return result;} INTERPOSE(isolated_ftruncate,ftruncate);
static void *isolated_mmap(void *address,size_t length,int protection,int flags,int fd,off_t offset){void *result=mmap(address,length,protection,flags,fd,offset);if(result==MAP_FAILED&&getenv("MSI_TRACE")){int saved=errno;fprintf(stderr,"[MacSteam] mmap failed: fd=%d length=%zu protection=%x flags=%x errno=%d\n",fd,length,protection,flags,saved);errno=saved;}return result;} INTERPOSE(isolated_mmap,mmap);
/* Steam's client IPC endpoints ("Steam3Master", "SteamClientService") are
   fixed loopback ports 57343/57344. A second client cannot bind them, so its
   games connected to the user's own Steam and signed in with that account.
   Each profile uses its own pair below the ephemeral range; the kernel profile
   also blocks the real ports. Programs still see the original numbers. */
static uint16_t steam_port(uint16_t port){
    if(!ready||(port!=57343&&port!=57344))return port;
    return (uint16_t)(30000+(hash_name(namespace_id)%9500)*2+(port-57343));
}
static uint16_t original_port(uint16_t port){
    uint16_t base=steam_port(57343);
    return ready&&(port==base||port==base+1)?(uint16_t)(57343+(port-base)):port;
}
static in_port_t *address_port(struct sockaddr *address,socklen_t length){
    if(address->sa_family==AF_INET&&length>=(socklen_t)sizeof(struct sockaddr_in))return &((struct sockaddr_in*)address)->sin_port;
    if(address->sa_family==AF_INET6&&length>=(socklen_t)sizeof(struct sockaddr_in6))return &((struct sockaddr_in6*)address)->sin6_port;
    return NULL;
}
static const struct sockaddr *socket_address(const struct sockaddr *address,socklen_t length,struct sockaddr_storage *storage,socklen_t *new_length){
    if(!ready||!address)return address;
    if(address->sa_family==AF_INET||address->sa_family==AF_INET6){
        if(length>(socklen_t)sizeof(*storage))return address;
        memcpy(storage,address,length);in_port_t *port=address_port((struct sockaddr*)storage,length);
        if(!port)return address;uint16_t mapped=steam_port(ntohs(*port));
        if(mapped==ntohs(*port))return address;*port=htons(mapped);return (struct sockaddr*)storage;
    }
    if(address->sa_family!=AF_UNIX||length<=offsetof(struct sockaddr_un,sun_path))return address;
    struct sockaddr_un *copy=(struct sockaddr_un*)storage;
    const struct sockaddr_un *un=(const void*)address;size_t available=length-sizeof(un->sun_family)-sizeof(un->sun_len);
    if(available>sizeof(un->sun_path))available=sizeof(un->sun_path);if(!memchr(un->sun_path,0,available))return address;
    char b[PATH_MAX];const char *p=map_path(un->sun_path,b);if(!p)return NULL;if(p==un->sun_path)return address;
    if(strlen(p)>=sizeof(copy->sun_path)){errno=ENAMETOOLONG;return NULL;}
    memset(copy,0,sizeof(*copy));copy->sun_family=AF_UNIX;strcpy(copy->sun_path,p);*new_length=(socklen_t)(offsetof(struct sockaddr_un,sun_path)+strlen(p)+1);copy->sun_len=(uint8_t)*new_length;return (void*)copy;
}
static int isolated_bind(int fd,const struct sockaddr *address,socklen_t length){struct sockaddr_storage storage;const struct sockaddr *p=socket_address(address,length,&storage,&length);return p?bind(fd,p,length):-1;} INTERPOSE(isolated_bind,bind);
static int isolated_connect(int fd,const struct sockaddr *address,socklen_t length){struct sockaddr_storage storage;const struct sockaddr *p=socket_address(address,length,&storage,&length);return p?connect(fd,p,length):-1;} INTERPOSE(isolated_connect,connect);
static void report_port(int result,struct sockaddr *address,socklen_t *length){
    if(result||!ready||!address||!length)return;in_port_t *port=address_port(address,*length);
    if(port)*port=htons(original_port(ntohs(*port)));
}
static int isolated_getsockname(int fd,struct sockaddr *address,socklen_t *length){int result=getsockname(fd,address,length);report_port(result,address,length);return result;} INTERPOSE(isolated_getsockname,getsockname);
static int isolated_getpeername(int fd,struct sockaddr *address,socklen_t *length){int result=getpeername(fd,address,length);report_port(result,address,length);return result;} INTERPOSE(isolated_getpeername,getpeername);

static char **child_environment(char *const original[],const char *program){
    if(!ready)return NULL;extern char **environ;char *const *source=original?original:environ;size_t count=0;
    while(source[count])count++;
    char **out=calloc(count+32,sizeof(char*));if(!out)return NULL;size_t written=0;
    for(size_t i=0;i<count;i++){
        int skip=0;for(unsigned k=0;environment_keys[k];k++){size_t n=strlen(environment_keys[k]);if(!strncmp(source[i],environment_keys[k],n)&&source[i][n]=='='){skip=1;break;}}
        if(!skip){out[written]=strdup(source[i]);if(!out[written])goto fail;written++;}
    }
    for(unsigned k=0;environment_keys[k];k++){
        const char *value=preserved_environment[k];if(!value)continue;
        if(!strcmp(environment_keys[k],"DYLD_INSERT_LIBRARIES")&&program&&prefix(program,app_private)){
            for(unsigned j=0;environment_keys[j];j++)if(!strcmp(environment_keys[j],"MSI_ISOLATION_LIBRARY")&&preserved_environment[j])value=preserved_environment[j];
        }
        if(asprintf(&out[written],"%s=%s",environment_keys[k],value)<0)goto fail;written++;
    }
    return out;
fail:for(size_t i=0;i<written;i++)free(out[i]);free(out);errno=ENOMEM;return NULL;
}
static void free_environment(char **env){if(env){for(size_t i=0;env[i];i++)free(env[i]);free(env);}}
static const char *preserved_value(const char *key){
    for(unsigned i=0;environment_keys[i];i++)if(!strcmp(key,environment_keys[i]))return preserved_environment[i];
    return NULL;
}
/* A whole-word /bin/ps in a shell command, as written by Steam. */
static int ps_word(const char *command,const char *p){
    return ps_tool[0]&&(p==command||strchr(" \t\n;|&(",p[-1]))&&(!p[7]||strchr(" \t\n;|&)",p[7]));
}
static const char *tool_path(const char *path){
    return ready&&ps_tool[0]&&path&&!strcmp(path,"/bin/ps")?ps_tool:path;
}
static char *shell_command(const char *command){
    /* Protected Apple shells strip DYLD_* at exec. Restore only our captured
       profile values inside the command, so the eventual helper is injected.
       Shells/helpers always receive the universal core, never a game's SBPE. */
    if(!ready||!command)return NULL;
    size_t capacity=strlen(command)+1,tool_length=strlen(ps_tool_quoted);
    for(const char *p=strstr(command,"/bin/ps");p;p=strstr(p+7,"/bin/ps"))
        if(ps_word(command,p)){if(tool_length>SIZE_MAX-capacity){errno=ENOMEM;return NULL;}capacity+=tool_length;}
    for(unsigned i=0;environment_keys[i];i++){
        const char *value=!strcmp(environment_keys[i],"DYLD_INSERT_LIBRARIES")?preserved_value("MSI_ISOLATION_LIBRARY"):preserved_environment[i];
        if(!value)continue;size_t length=strlen(value),key_length=strlen(environment_keys[i]);
        if(length>(SIZE_MAX-capacity-key_length-16)/4){errno=ENOMEM;return NULL;}
        capacity+=key_length+16+4*length;
    }
    char *result=malloc(capacity);if(!result)return NULL;char *out=result;
    for(unsigned i=0;environment_keys[i];i++){
        const char *value=!strcmp(environment_keys[i],"DYLD_INSERT_LIBRARIES")?preserved_value("MSI_ISOLATION_LIBRARY"):preserved_environment[i];
        if(!value)continue;
        out+=sprintf(out,"export %s='",environment_keys[i]);
        for(;*value;value++){
            if(*value=='\''){memcpy(out,"'\\''",4);out+=4;}else *out++=*value;
        }
        memcpy(out,"';\n",3);out+=3;
    }
    for(const char *p=command;*p;){
        if(!strncmp(p,"/bin/ps",7)&&ps_word(command,p)){memcpy(out,ps_tool_quoted,tool_length);out+=tool_length;p+=7;}
        else *out++=*p++;
    }
    *out=0;return result;
}
static int system_shell(const char *path){
    if(!path)return 0;
    return !strcmp(path,"/bin/sh")||!strcmp(path,"/bin/bash")||!strcmp(path,"/bin/zsh")||
           !strcmp(path,"sh")||!strcmp(path,"bash")||!strcmp(path,"zsh");
}
struct shell_arguments {char **values;char *command;};
static int shell_arguments(const char *path,char *const argv[],struct shell_arguments *result){
    memset(result,0,sizeof(*result));if(!ready||!system_shell(path)||!argv)return 0;
    size_t count=0;while(argv[count])count++;
    for(size_t i=1;i<count;i++){
        const char *option=argv[i];if(!strcmp(option,"--")||option[0]!='-'||!option[1])break;
        if(!strcmp(option,"-o")||!strcmp(option,"-O")){i++;continue;}
        if(option[1]=='-'||!strchr(option+1,'c'))continue;
        size_t script=i+1;if(script<count&&!strcmp(argv[script],"--"))script++;
        if(script>=count)return 0;
        result->command=shell_command(argv[script]);if(!result->command)return ENOMEM;
        result->values=calloc(count+1,sizeof(char*));if(!result->values){free(result->command);result->command=NULL;return ENOMEM;}
        memcpy(result->values,argv,count*sizeof(char*));result->values[script]=result->command;return 0;
    }
    return 0;
}
static void free_shell_arguments(struct shell_arguments *arguments){free(arguments->values);free(arguments->command);}
static FILE *isolated_popen(const char *command,const char *mode){
    if(!ready||!command)return popen(command,mode);
    char *wrapped=shell_command(command);if(!wrapped)return NULL;
    FILE *result=popen(wrapped,mode);int saved=errno;free(wrapped);errno=saved;return result;
} INTERPOSE(isolated_popen,popen);
static int isolated_system(const char *command){
    if(!ready||!command)return system(command);
    char *wrapped=shell_command(command);if(!wrapped)return -1;
    int result=system(wrapped),saved=errno;free(wrapped);errno=saved;return result;
} INTERPOSE(isolated_system,system);
static int blocked_program(const char *path){return ready&&path&&(!strcmp(path,"/bin/launchctl")||!strcmp(path,"/usr/bin/killall")||!strcmp(path,"/usr/bin/osascript")||!strcmp(path,"/usr/bin/open"));}
static int isolated_spawn(pid_t *pid,const char *path,const posix_spawn_file_actions_t *actions,const posix_spawnattr_t *attrs,char *const argv[],char *const env[]){
    if(blocked_program(path))return EPERM;char b[PATH_MAX];const char *p=tool_path(map_path(path,b));if(!p)return errno;
    struct shell_arguments args;int error=shell_arguments(p,argv,&args);if(error)return error;
    char **merged=child_environment(env,p);if(ready&&!merged){free_shell_arguments(&args);return ENOMEM;}
    int result=posix_spawn(pid,p,actions,attrs,args.values?args.values:argv,merged?merged:env);free_environment(merged);free_shell_arguments(&args);return result;
} INTERPOSE(isolated_spawn,posix_spawn);
static int isolated_spawnp(pid_t *pid,const char *path,const posix_spawn_file_actions_t *actions,const posix_spawnattr_t *attrs,char *const argv[],char *const env[]){
    if(blocked_program(path))return EPERM;char b[PATH_MAX];const char *p=tool_path(ready&&ps_tool[0]&&path&&!strcmp(path,"ps")?"/bin/ps":map_path(path,b));if(!p)return errno;
    struct shell_arguments args;int error=shell_arguments(p,argv,&args);if(error)return error;
    char **merged=child_environment(env,p);if(ready&&!merged){free_shell_arguments(&args);return ENOMEM;}
    int result=posix_spawnp(pid,p,actions,attrs,args.values?args.values:argv,merged?merged:env);free_environment(merged);free_shell_arguments(&args);return result;
} INTERPOSE(isolated_spawnp,posix_spawnp);
static int isolated_execve(const char *path,char *const argv[],char *const env[]){
    if(blocked_program(path)){errno=EPERM;return -1;}char b[PATH_MAX];const char *p=tool_path(map_path(path,b));if(!p)return -1;
    struct shell_arguments args;int error=shell_arguments(p,argv,&args);if(error){errno=error;return -1;}
    char **merged=child_environment(env,p);if(ready&&!merged){free_shell_arguments(&args);return -1;}
    int result=execve(p,args.values?args.values:argv,merged?merged:env);int saved=errno;free_environment(merged);free_shell_arguments(&args);errno=saved;return result;
} INTERPOSE(isolated_execve,execve);
static int isolated_execv(const char *path,char *const argv[]){extern char **environ;return isolated_execve(path,argv,environ);} INTERPOSE(isolated_execv,execv);
static int isolated_execvp(const char *file,char *const argv[]){
    if(!ready)return execvp(file,argv);if(strchr(file,'/'))return isolated_execv(file,argv);
    const char *search=getenv("PATH");if(!search)search="/usr/bin:/bin";int denied=0;
    const char *begin=search;for(;;){const char *end=strchr(begin,':');size_t length=end?(size_t)(end-begin):strlen(begin);
        char candidate[PATH_MAX];int size=length?snprintf(candidate,sizeof(candidate),"%.*s/%s",(int)length,begin,file):snprintf(candidate,sizeof(candidate),"%s",file);
        if(size>0&&size<(int)sizeof(candidate)){isolated_execv(candidate,argv);if(errno==EACCES)denied=1;else if(errno!=ENOENT&&errno!=ENOTDIR)return -1;}
        if(!end)break;begin=end+1;
    }errno=denied?EACCES:ENOENT;return -1;
} INTERPOSE(isolated_execvp,execvp);
static int isolated_kill(pid_t pid,int signal_number){
    /* The kernel profile denies signals to protect existing applications.
       Steam's helper still needs the non-signalling kill(pid,0) liveness test. */
    if(ready&&signal_number==0&&pid>0){struct proc_bsdinfo info;
        if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))==(int)sizeof(info))return 0;
        errno=ESRCH;return -1;}
    return kill(pid,signal_number);
} INTERPOSE(isolated_kill,kill);
