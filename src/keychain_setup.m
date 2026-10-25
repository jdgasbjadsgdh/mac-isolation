/* Runs only in a private profile. Never resets a login keychain or changes the
 * system/user default/search-list APIs. Password material stays in this process. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

static int generic_items=-1;
static void report(OSStatus status,const char *phase,NSString *path){
    NSDictionary *value=@{@"status":@(status),@"phase":[NSString stringWithUTF8String:phase],@"path":path?:@"",@"generic_items":@(generic_items)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);
}
int main(int argc,char **argv){@autoreleasepool{
    const char *home=getenv("MSI_PRIVATE_HOME"),*ns=getenv("MSI_NAMESPACE");
    if(!home||!ns||strlen(ns)!=32||strcmp(home,[NSHomeDirectory() fileSystemRepresentation]))return 2;
    NSString *directory=[[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Library/Keychains"];
    NSString *path=[directory stringByAppendingPathComponent:@"login.keychain"];
    NSString *secret=[directory stringByAppendingPathComponent:@"unlock.secret"];
    int fd=open(secret.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    struct stat st={0};char password[64]={0};
    if(fd<0||fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&077)||st.st_size!=sizeof(password))return 3;
    ssize_t used=read(fd,password,sizeof(password));close(fd);if(used!=sizeof(password))return 4;
    SecKeychainSetUserInteractionAllowed(false);
    SecKeychainRef keychain=NULL;OSStatus status=0;
    BOOL exists=[[NSFileManager defaultManager] fileExistsAtPath:path]||[[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingString:@"-db"]];
    status=exists?SecKeychainOpen(path.fileSystemRepresentation,&keychain):SecKeychainCreate(path.fileSystemRepresentation,sizeof(password),password,false,NULL,&keychain);
    if(!status)status=SecKeychainUnlock(keychain,sizeof(password),password,true);
    for(volatile char *wipe=password;wipe<password+sizeof(password);wipe++)*wipe=0;
    if(status){report(status,"open-or-create",path);if(keychain)CFRelease(keychain);return 5;}
    // Confirm that NULL-keychain calls used by Steam resolve inside this home.
    SecKeychainRef default_keychain=NULL;status=SecKeychainCopyDefault(&default_keychain);
    UInt32 size=PATH_MAX;char resolved[PATH_MAX]={0};
    if(!status)status=SecKeychainGetPath(default_keychain,&size,resolved);
    if(!status&&(strncmp(resolved,home,strlen(home))||resolved[strlen(home)]!='/'))status=errSecInvalidKeychain;
    if(default_keychain)CFRelease(default_keychain);
    if(!status&&argc==2&&!strcmp(argv[1],"probe")){
        const char *service="com.macsteam.isolation.keychain.fixture",*account="fixture",*value=ns;
        SecKeychainItemRef item=NULL;
        status=SecKeychainAddGenericPassword(NULL,(UInt32)strlen(service),service,(UInt32)strlen(account),account,(UInt32)strlen(value),value,&item);
        if(status==errSecDuplicateItem)status=SecKeychainFindGenericPassword(NULL,(UInt32)strlen(service),service,(UInt32)strlen(account),account,NULL,NULL,&item);
        if(!status){
            UInt32 length=0;void *data=NULL;
            status=SecKeychainFindGenericPassword(NULL,(UInt32)strlen(service),service,(UInt32)strlen(account),account,&length,&data,NULL);
            if(!status&&(length!=strlen(value)||memcmp(data,value,length)))status=errSecInvalidData;
            if(data)SecKeychainItemFreeContent(NULL,data);
        }
        if(item){OSStatus removed=SecKeychainItemDelete(item);if(!status)status=removed;CFRelease(item);}
    }
    if(!status&&argc==2&&!strcmp(argv[1],"count")){
        SecKeychainSearchRef search=NULL;
        status=SecKeychainSearchCreateFromAttributes(keychain,kSecGenericPasswordItemClass,NULL,&search);
        if(!status){
            generic_items=0;SecKeychainItemRef item=NULL;
            while(!(status=SecKeychainSearchCopyNext(search,&item))){generic_items++;CFRelease(item);item=NULL;}
            if(status==errSecItemNotFound)status=0;CFRelease(search);
        }
    }
    report(status,"default-and-unlock",[NSString stringWithUTF8String:resolved]);CFRelease(keychain);return status?6:0;
}}
