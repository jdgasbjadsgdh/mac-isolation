#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <servers/bootstrap.h>
#include <mach/mach.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <spawn.h>
#include <pwd.h>
#include <semaphore.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <dlfcn.h>
#include <signal.h>
#include <sandbox.h>

static void json(NSDictionary *value){NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);}
static NSString *string(const char *s){return s?[NSString stringWithUTF8String:s]:@"";}
static NSString *shell_quote(const char *s){return [@"'" stringByAppendingString:[[string(s) stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"] stringByAppendingString:@"'"]];}
struct Request {mach_msg_header_t header;uint32_t value;};
struct Reply {mach_msg_header_t header;uint32_t value;};
int main(int argc,char **argv){@autoreleasepool{
    if(argc<2)return 2;
    if(!strcmp(argv[1],"sandbox-nesting")){
        char *error=NULL;int result=sandbox_init("(version 1) (allow default)",0,&error),saved=errno;
        json(@{@"result":@(result),@"errno":@(result<0?saved:0),@"error":string(error)});
        if(error)sandbox_free_error(error);return 0;
    }
    if(!strcmp(argv[1],"identity")){
        struct passwd p,*result=NULL;char b[8192];int status=getpwuid_r(getuid(),&p,b,sizeof(b),&result);
        json(@{@"home":string(getenv("HOME")),@"pw_home":string(getpwuid(getuid())->pw_dir),@"pw_r_home":status?@"ERROR":string(p.pw_dir),@"foundation_home":NSHomeDirectory(),@"foundation_tmp":NSTemporaryDirectory(),@"uid":@(getuid()),@"namespace":string(getenv("MSI_NAMESPACE")),@"insertion":string(getenv("DYLD_INSERT_LIBRARIES")),@"languages":[NSLocale preferredLanguages],@"alive":@(kill(getpid(),0)==0)});return 0;
    }
    if(!strncmp(argv[1],"shell-",6)){
        if(!strcmp(argv[1],"shell-command")){
            if(argc<4)return 2;
            char *child[]={argv[2],"-c",argv[3],"fixture $zero;",argc>4?argv[4]:"argument ' $one;",NULL};
            execv(argv[2],child);return 93;
        }
        NSString *command=[shell_quote(argv[0]) stringByAppendingString:@" identity"];
        const char *mode=argv[1]+6;
        if(!strncmp(mode,"scrubbed-",9)){
            mode+=9;
            const char *keys[]={"HOME","CFFIXED_USER_HOME","TMPDIR","DYLD_INSERT_LIBRARIES","MSI_ISOLATION_LIBRARY","MSI_PRIVATE_HOME","MSI_PRIMARY_HOME","MSI_STEAM_SOURCE","MSI_STEAM_PRIVATE","MSI_APP_SOURCE","MSI_APP_PRIVATE","MSI_IPC_ROOT","MSI_NAMESPACE",NULL};
            for(unsigned i=0;keys[i];i++)unsetenv(keys[i]);
        }
        if(!strcmp(mode,"system")){
            int status=system(command.UTF8String);return WIFEXITED(status)?WEXITSTATUS(status):90;
        }
        if(!strcmp(mode,"popen")){
            FILE *pipe=popen(command.UTF8String,"r");if(!pipe)return 91;
            char data[4096];size_t count;while((count=fread(data,1,sizeof(data),pipe)))fwrite(data,1,count,stdout);
            int status=pclose(pipe);return WIFEXITED(status)?WEXITSTATUS(status):92;
        }
        char *child[]={"sh","-c",(char*)command.UTF8String,NULL};
        char *dash_child[]={"sh","-c","--",(char*)command.UTF8String,NULL};
        char *combined_child[]={"sh","-ec",(char*)command.UTF8String,NULL};
        if(!strcmp(mode,"exec")){execv("/bin/sh",child);return 93;}
        pid_t pid=0;char *minimal[]={"PATH=/usr/bin:/bin",NULL};
        char **args=!strcmp(mode,"dash")?dash_child:!strcmp(mode,"combined")?combined_child:child;
        int result=!strcmp(mode,"spawnp")?posix_spawnp(&pid,"sh",NULL,NULL,args,minimal):posix_spawn(&pid,"/bin/sh",NULL,NULL,args,minimal);
        if(result)return 94;int status=0;waitpid(pid,&status,0);return WIFEXITED(status)?WEXITSTATUS(status):95;
    }
    if(!strcmp(argv[1],"files")){
        if(argc!=4)return 2;const char *path=argv[2];int fd=open(path,O_WRONLY|O_CREAT|O_TRUNC,0600);if(fd<0)return 10;
        if(write(fd,argv[3],strlen(argv[3]))!=(ssize_t)strlen(argv[3]))return 11;close(fd);
        struct stat st;int found=stat(path,&st);char actual[PATH_MAX];char *resolved=realpath(path,actual);
        fd=open(path,O_RDONLY);char b[128]={0};if(fd<0)return 12;read(fd,b,sizeof(b)-1);close(fd);
        json(@{@"value":string(b),@"size":@(found==0?st.st_size:-1),@"actual":resolved?string(actual):@""});return 0;
    }
    if(!strcmp(argv[1],"fifo")){
        if(argc!=3)return 2;const char *path=argv[2];unlink(path);
        if(mkfifo(path,0600))return 60;int fd=open(path,O_RDWR|O_NONBLOCK);if(fd<0)return 61;
        char value=0;if(write(fd,"Y",1)!=1||read(fd,&value,1)!=1||value!='Y')return 62;
        close(fd);unlink(path);json(@{@"fifo":@YES});return 0;
    }
    if(!strcmp(argv[1],"library")){
        if(argc!=3)return 2;void *library=dlopen(argv[2],RTLD_NOW|RTLD_LOCAL);if(!library)return 70;
        int (*value)(void)=dlsym(library,"msi_fixture_value");if(!value)return 71;
        Dl_info info;if(!dladdr(value,&info))return 72;
        json(@{@"value":@(value()),@"loaded_path":string(info.dli_fname)});dlclose(library);return 0;
    }
    if(!strcmp(argv[1],"signal-tree")){
        pid_t child=fork();if(child<0)return 80;if(child==0){for(;;)pause();}
        if(kill(child,SIGTERM))return 81;int status=0;waitpid(child,&status,0);
        if(!WIFSIGNALED(status)||WTERMSIG(status)!=SIGTERM)return 82;
        json(@{@"child_signal":@YES});return 0;
    }
    if(!strcmp(argv[1],"signal-outside")){
        if(argc!=3)return 2;int result=kill((pid_t)atoi(argv[2]),SIGCONT);int saved=errno;
        json(@{@"denied":@(result<0&&saved==EPERM)});return 0;
    }
    if(!strcmp(argv[1],"wait")){puts("READY");fflush(stdout);for(;;)pause();}
    if(!strcmp(argv[1],"ipc-create")){
        if(argc!=3)return 2;
        sem_t *s=sem_open("/msi_fixture_fixed_sem",O_CREAT|O_EXCL,0600,1);if(s==SEM_FAILED)return 20;
        int fd=shm_open("/msi_fixture_fixed_shm",O_CREAT|O_EXCL|O_RDWR,0600);if(fd<0)return 21;
        if(ftruncate(fd,4096))return 22;void *p=mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(p==MAP_FAILED)return 23;
        struct stat status;if(fstat(fd,&status))return 27;
        strncpy(p,argv[2],4095);munmap(p,4096);close(fd);sem_close(s);json(@{@"created":@YES,@"mode":@(status.st_mode&0777)});return 0;
    }
    if(!strcmp(argv[1],"ipc-read")){
        sem_t *s=sem_open("/msi_fixture_fixed_sem",0);if(s==SEM_FAILED)return 24;
        int fd=shm_open("/msi_fixture_fixed_shm",O_RDONLY,0);if(fd<0)return 25;
        const char *p=mmap(NULL,4096,PROT_READ,MAP_SHARED,fd,0);if(p==MAP_FAILED)return 26;
        NSString *value=string(p);munmap((void*)p,4096);close(fd);sem_close(s);json(@{@"value":value});return 0;
    }
    if(!strcmp(argv[1],"tcp-serve")){
        if(argc!=4)return 2;int fd=socket(AF_INET,SOCK_STREAM,0),one=1;setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
        struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons((uint16_t)atoi(argv[2])),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        if(bind(fd,(struct sockaddr*)&address,sizeof(address))||listen(fd,1)){printf("ERROR %d\n",errno);return 30;}
        struct sockaddr_in local;socklen_t length=sizeof(local);getsockname(fd,(struct sockaddr*)&local,&length);
        printf("READY %d\n",ntohs(local.sin_port));fflush(stdout);
        fd_set set;FD_ZERO(&set);FD_SET(fd,&set);struct timeval wait={5,0};if(select(fd+1,&set,NULL,NULL,&wait)<=0)return 31;
        int client=accept(fd,NULL,NULL);if(client<0)return 32;write(client,argv[3],strlen(argv[3]));close(client);close(fd);return 0;
    }
    if(!strcmp(argv[1],"tcp-get")){
        if(argc!=3)return 2;int fd=socket(AF_INET,SOCK_STREAM,0);
        struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons((uint16_t)atoi(argv[2])),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        int result=connect(fd,(struct sockaddr*)&address,sizeof(address)),error=result?errno:0;char token[64]={0};
        if(!result)read(fd,token,sizeof(token)-1);json(@{@"error":@(error),@"token":string(token)});return 0;
    }
    if(!strcmp(argv[1],"dnc-listen")){
        if(argc!=4)return 2;__block int count=0;
        [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@(argv[2]) object:nil queue:nil usingBlock:^(NSNotification *n){count++;}];
        printf("READY\n");fflush(stdout);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:atof(argv[3])]];
        json(@{@"count":@(count)});return 0;
    }
    if(!strcmp(argv[1],"dnc-post")){
        if(argc!=3)return 2;
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@(argv[2]) object:nil userInfo:nil deliverImmediately:YES];return 0;
    }
    if(!strcmp(argv[1],"ls-hold")){
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
        printf("READY\n");fflush(stdout);sleep(10);return 0;
    }
    if(!strcmp(argv[1],"ls-self")){
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
        char command[128];snprintf(command,sizeof(command),"/usr/bin/lsappinfo info -only bundleID $(/usr/bin/lsappinfo find pid=%d)",getpid());
        FILE *pipe=popen(command,"r");char output[512]={0};if(pipe){fread(output,1,sizeof(output)-1,pipe);pclose(pipe);}
        json(@{@"launch_services":string(output),@"bundle":[NSBundle mainBundle].bundleIdentifier?:@"",
               @"running":[NSRunningApplication currentApplication].bundleIdentifier?:@""});return 0;
    }
    if(!strcmp(argv[1],"apps")){
        if(argc!=3)return 2;NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[2])];
        NSMutableArray *same=[NSMutableArray array];
        for(NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.valvesoftware.steam"])[same addObject:@(other.processIdentifier)];
        json(@{@"bundle":app.bundleIdentifier?:@"",@"same":same});return 0;
    }
    if(!strcmp(argv[1],"popen-command")){
        if(argc!=3)return 2;FILE *pipe=popen(argv[2],"r");if(!pipe)return 91;
        char data[4096];size_t count;while((count=fread(data,1,sizeof(data),pipe)))fwrite(data,1,count,stdout);
        int status=pclose(pipe);return WIFEXITED(status)?WEXITSTATUS(status):92;
    }
    if(!strcmp(argv[1],"spawn-argv")){
        if(argc<3)return 2;extern char **environ;pid_t pid=0;
        int result=posix_spawn(&pid,argv[2],NULL,NULL,argv+2,environ);if(result){fprintf(stderr,"spawn errno %d\n",result);return 94;}
        int status=0;waitpid(pid,&status,0);return WIFEXITED(status)?WEXITSTATUS(status):95;
    }
    if(!strcmp(argv[1],"ipc-clean")){sem_unlink("/msi_fixture_fixed_sem");shm_unlink("/msi_fixture_fixed_shm");return 0;}
    if(!strcmp(argv[1],"ipc-raw")){
        if(argc!=5)return 2;
        BOOL unlinking=!strcmp(argv[4],"unlink"),creating=!strcmp(argv[4],"create");
        int fd=unlinking?shm_unlink(argv[2]):shm_open(argv[2],O_RDWR|(creating?(O_CREAT|O_EXCL):0),0600);
        int shm_error=fd<0?errno:0;if(!unlinking&&fd>=0)close(fd);
        int sem_error=0;
        if(unlinking){if(sem_unlink(argv[3]))sem_error=errno;}
        else {sem_t *sem=sem_open(argv[3],creating?(O_CREAT|O_EXCL):0,0600,1);if(sem==SEM_FAILED)sem_error=errno;else sem_close(sem);}
        json(@{@"shm_error":@(shm_error),@"sem_error":@(sem_error)});return 0;
    }
    if(!strcmp(argv[1],"preferences")){
        CFStringRef app=CFSTR("com.valvesoftware.MSIProbe"),key=CFSTR("FixtureValue");
        if(argc==3){CFStringRef value=CFStringCreateWithCString(NULL,argv[2],kCFStringEncodingUTF8);CFPreferencesSetAppValue(key,value,app);CFRelease(value);CFPreferencesAppSynchronize(app);}
        CFPropertyListRef value=CFPreferencesCopyAppValue(key,app);json(@{@"value":value?(__bridge id)value:[NSNull null]});if(value)CFRelease(value);return 0;
    }
    if(!strcmp(argv[1],"preferences-clean")){CFPreferencesSetAppValue(CFSTR("FixtureValue"),NULL,CFSTR("com.valvesoftware.MSIProbe"));CFPreferencesAppSynchronize(CFSTR("com.valvesoftware.MSIProbe"));return 0;}
    if(!strcmp(argv[1],"unix-server")){
        int fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un address={.sun_family=AF_UNIX};strcpy(address.sun_path,"/tmp/steam-msi-fixture.sock");
        unlink(address.sun_path);if(bind(fd,(void*)&address,sizeof(address))||listen(fd,1))return 30;
        puts("READY");fflush(stdout);int other=accept(fd,NULL,NULL);if(other<0)return 31;
        if(write(other,argv[2],strlen(argv[2]))<0)return 32;close(other);close(fd);unlink(address.sun_path);return 0;
    }
    if(!strcmp(argv[1],"unix-client")){
        int fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un address={.sun_family=AF_UNIX};strcpy(address.sun_path,"/tmp/steam-msi-fixture.sock");
        if(connect(fd,(void*)&address,sizeof(address)))return 33;char b[128]={0};if(read(fd,b,sizeof(b)-1)<0)return 34;close(fd);json(@{@"value":string(b)});return 0;
    }
    if(!strcmp(argv[1],"mach-server")){
        mach_port_t port=MACH_PORT_NULL;kern_return_t kr=bootstrap_check_in(bootstrap_port,"com.valvesoftware.steam.ipctool",&port);if(kr)return 40;
        fprintf(stderr,"fixture check-in: port=%u namespace=%s\n",port,getenv("MSI_NAMESPACE"));fflush(stderr);
        for(;;){struct {struct Request message;mach_msg_max_trailer_t trailer;} request={0};kr=mach_msg(&request.message.header,MACH_RCV_MSG,0,sizeof(request),port,MACH_MSG_TIMEOUT_NONE,MACH_PORT_NULL);if(kr)return 41;
            fprintf(stderr,"fixture received: id=%d reply=%u\n",request.message.header.msgh_id,request.message.header.msgh_remote_port);fflush(stderr);
            struct Reply reply={0};reply.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.header.msgh_size=sizeof(reply);reply.header.msgh_remote_port=request.message.header.msgh_remote_port;reply.header.msgh_id=request.message.header.msgh_id+100;reply.value=(uint32_t)strtoul(getenv("MSI_FIXTURE_MARKER"),NULL,10);
            kr=mach_msg(&reply.header,MACH_SEND_MSG,sizeof(reply),0,MACH_PORT_NULL,0,MACH_PORT_NULL);fprintf(stderr,"fixture reply: result=%d\n",kr);fflush(stderr);if(kr)return 42;}
    }
    if(!strcmp(argv[1],"mach-client")){
        mach_port_t service=MACH_PORT_NULL,reply=MACH_PORT_NULL;kern_return_t kr=bootstrap_look_up(bootstrap_port,"com.valvesoftware.steam.ipctool",&service);
        if(kr){json(@{@"lookup_error":@(kr)});return 43;}mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&reply);
        fprintf(stderr,"fixture lookup: service=%u reply=%u namespace=%s\n",service,reply,getenv("MSI_NAMESPACE"));fflush(stderr);
        struct Request request={0};request.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE);request.header.msgh_size=sizeof(request);request.header.msgh_remote_port=service;request.header.msgh_local_port=reply;request.header.msgh_id=800;
        kr=mach_msg(&request.header,MACH_SEND_MSG,sizeof(request),0,MACH_PORT_NULL,0,MACH_PORT_NULL);if(kr)return 44;
        struct {struct Reply message;mach_msg_max_trailer_t trailer;} result={0};kr=mach_msg(&result.message.header,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof(result),reply,10000,MACH_PORT_NULL);if(kr)return 45;
        json(@{@"marker":@(result.message.value)});mach_port_destroy(mach_task_self(),reply);mach_port_deallocate(mach_task_self(),service);return 0;
    }
    if(!strcmp(argv[1],"spawn")||!strcmp(argv[1],"spawn-scrubbed")||!strcmp(argv[1],"spawnp")){
        if(!strcmp(argv[1],"spawn-scrubbed")){
            const char *keys[]={"HOME","CFFIXED_USER_HOME","TMPDIR","DYLD_INSERT_LIBRARIES","MSI_ISOLATION_LIBRARY","MSI_PRIVATE_HOME","MSI_PRIMARY_HOME","MSI_STEAM_SOURCE","MSI_STEAM_PRIVATE","MSI_APP_SOURCE","MSI_APP_PRIVATE","MSI_IPC_ROOT","MSI_NAMESPACE",NULL};
            for(unsigned i=0;keys[i];i++)unsetenv(keys[i]);
        }
        char *child[]={argv[0],"identity",NULL};char *minimal[]={"PATH=/usr/bin:/bin",NULL};pid_t pid=0;
        int result=!strcmp(argv[1],"spawnp")?posix_spawnp(&pid,argv[0],NULL,NULL,child,minimal):posix_spawn(&pid,argv[0],NULL,NULL,child,minimal);if(result)return 50;int status=0;waitpid(pid,&status,0);return WIFEXITED(status)?WEXITSTATUS(status):51;
    }
    if(!strcmp(argv[1],"execv")||!strcmp(argv[1],"execvp")){
        char *child[]={argv[0],"identity",NULL};
        if(!strcmp(argv[1],"execvp"))execvp(argv[0],child);else execv(argv[0],child);
        return 52;
    }
    return 2;
}}
