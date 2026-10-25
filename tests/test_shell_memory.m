/* ASan itself intercepts mmap/open. Exercise the actual launch builders without
 * replacing those sanitizer bootstrap functions. Full interposition is covered
 * separately by the native process fixtures. */
#define INTERPOSE(new,old)
#include "../src/isolation.m"
#include <assert.h>
int main(void){@autoreleasepool{
    unsigned trace=0;while(strcmp(environment_keys[trace],"MSI_TRACE"))trace++;
    const char alphabet[]="'\"$`;\\\n ABC012";
    char command[4097],value[8193];unsigned state=12345;
    for(unsigned iteration=0;iteration<2000;iteration++){
        size_t length=iteration%sizeof(command),extra=(iteration*37)%sizeof(value);
        for(size_t i=0;i<length;i++){state=state*1664525+1013904223;command[i]=alphabet[state%(sizeof(alphabet)-1)];}command[length]=0;
        for(size_t i=0;i<extra;i++){state=state*1664525+1013904223;value[i]=alphabet[state%(sizeof(alphabet)-1)];}value[extra]=0;
        free(preserved_environment[trace]);preserved_environment[trace]=strdup(value);
        char *wrapped=shell_command(command);assert(wrapped);
        size_t size=strlen(wrapped);assert(size>=length&&!strcmp(wrapped+size-length,command));free(wrapped);
        char *argv[]={"sh","-ec","--",command,"zero ' $","one ` ;",NULL};
        struct shell_arguments args;assert(!shell_arguments("/bin/sh",argv,&args));
        assert(args.values&&args.values[2]==argv[2]&&args.values[4]==argv[4]&&args.values[5]==argv[5]&&!args.values[6]);
        assert(args.values[3]==args.command&&argv[3]==command);free_shell_arguments(&args);
        char *env[]={"PATH=/usr/bin:/bin","HOME=ignored","MSI_NAMESPACE=ignored",NULL};
        char **merged=child_environment(env,app_private);assert(merged);
        unsigned count=0;for(char **p=merged;*p;p++)if(!strncmp(*p,"HOME=",5)){assert(!strcmp(*p+5,private_home));count++;}
        assert(count==1);free_environment(merged);
    }
    puts("ASan/UBSan: 2000 shell-command, argv and environment cases passed");return 0;
}}
