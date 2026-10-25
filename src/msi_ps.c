/* Minimal non-setuid ps for isolated Steam processes. The kernel refuses to
 * execute setuid binaries such as /bin/ps inside a Seatbelt sandbox, and Steam
 * checks its web UI connection with "/bin/ps -x -o pid=,ppid=". The process
 * table is read with sysctl(KERN_PROC), which needs no privileges. Supports the
 * selection options -A -e -a -x -p and -o/-O field lists (pid ppid pgid uid
 * user comm ucomm command args). */
#include <sys/sysctl.h>
#include <sys/types.h>
#include <libproc.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {F_PID,F_PPID,F_PGID,F_UID,F_USER,F_COMM,F_COMMAND};
struct field {int kind;char header[64];};
static struct field fields[32];
static int field_count, header_wanted;
static pid_t selected[256];
static int selected_count;

static int add_fields(const char *list){
    char *copy=strdup(list),*save=NULL;if(!copy)return -1;
    for(char *item=strtok_r(copy,", \t",&save);item;item=strtok_r(NULL,", \t",&save)){
        if(field_count>=(int)(sizeof(fields)/sizeof(*fields))){free(copy);return -1;}
        char *equals=strchr(item,'=');if(equals)*equals=0;
        static const struct {const char *name;int kind;const char *header;} known[]={
            {"pid",F_PID,"PID"},{"ppid",F_PPID,"PPID"},{"pgid",F_PGID,"PGID"},{"uid",F_UID,"UID"},
            {"user",F_USER,"USER"},{"comm",F_COMM,"COMM"},{"ucomm",F_COMM,"UCOMM"},
            {"command",F_COMMAND,"COMMAND"},{"args",F_COMMAND,"ARGS"}};
        int found=-1;for(unsigned i=0;i<sizeof(known)/sizeof(*known);i++)if(!strcmp(item,known[i].name))found=(int)i;
        if(found<0){fprintf(stderr,"ps: %s: keyword not found\n",item);free(copy);return -1;}
        struct field *f=&fields[field_count++];f->kind=known[found].kind;
        snprintf(f->header,sizeof(f->header),"%s",equals?equals+1:known[found].header);
        if(f->header[0])header_wanted=1;
    }
    free(copy);return 0;
}

static int add_pids(const char *list){
    char *copy=strdup(list),*save=NULL;if(!copy)return -1;
    for(char *item=strtok_r(copy,", \t",&save);item;item=strtok_r(NULL,", \t",&save)){
        char *end=NULL;long value=strtol(item,&end,10);
        if(*end||value<0||selected_count>=(int)(sizeof(selected)/sizeof(*selected))){free(copy);return -1;}
        selected[selected_count++]=(pid_t)value;
    }
    free(copy);return 0;
}

static void command_line(pid_t pid,const char *fallback,char *out,size_t size){
    int mib[3]={CTL_KERN,KERN_PROCARGS2,pid};size_t length=0;out[0]=0;
    if(!sysctl(mib,3,NULL,&length,NULL,0)&&length>sizeof(int)){
        char *buffer=malloc(length);
        if(buffer&&!sysctl(mib,3,buffer,&length,NULL,0)&&length>sizeof(int)){
            int argc;memcpy(&argc,buffer,sizeof(argc));char *p=buffer+sizeof(int),*end=buffer+length;
            while(p<end&&*p)p++;while(p<end&&!*p)p++;
            size_t used=0;
            for(int i=0;i<argc&&p<end;i++){
                size_t n=strnlen(p,(size_t)(end-p));
                if(used&&used+1<size)out[used++]=' ';
                size_t copy=n<size-used-1?n:size-used-1;memcpy(out+used,p,copy);used+=copy;out[used]=0;
                p+=n+1;
            }
        }
        free(buffer);
    }
    if(!out[0])snprintf(out,size,"%s",fallback);
}

static int by_pid(const void *a,const void *b){
    pid_t x=((const struct kinfo_proc*)a)->kp_proc.p_pid,y=((const struct kinfo_proc*)b)->kp_proc.p_pid;
    return (x>y)-(x<y);
}

int main(int argc,char **argv){
    int everyone=0,all_terminals=0;
    for(int i=1;i<argc;i++){
        const char *arg=argv[i];
        if(arg[0]!='-'||!arg[1])continue;
        for(const char *c=arg+1;*c;c++){
            if(*c=='A'||*c=='e')everyone=1;
            else if(*c=='a')all_terminals=1;
            else if(*c=='o'||*c=='O'||*c=='p'){
                const char *value=c[1]?c+1:(i+1<argc?argv[++i]:NULL);
                if(!value){fprintf(stderr,"ps: option requires an argument -- %c\n",*c);return 1;}
                if((*c=='p'?add_pids(value):add_fields(value))<0)return 1;
                break;
            }
        }
    }
    if(!field_count&&add_fields("pid,command")<0)return 1;
    if(all_terminals)everyone=1;

    int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};size_t length=0;struct kinfo_proc *table=NULL;
    for(int attempt=0;attempt<8;attempt++){
        if(sysctl(mib,4,NULL,&length,NULL,0))return 1;
        length+=length/8+16*sizeof(struct kinfo_proc);
        free(table);table=malloc(length);if(!table)return 1;
        if(!sysctl(mib,4,table,&length,NULL,0))break;
        free(table);table=NULL;
    }
    if(!table)return 1;
    size_t count=length/sizeof(struct kinfo_proc);uid_t me=getuid();

    if(header_wanted){
        for(int f=0;f<field_count;f++){
            int numeric=fields[f].kind<=F_UID,last=f==field_count-1;
            if(numeric)printf("%5s",fields[f].header);else if(last)printf("%s",fields[f].header);else printf("%-16s",fields[f].header);
            putchar(last?'\n':' ');
        }
    }
    qsort(table,count,sizeof(*table),by_pid);
    int matched=0;
    for(size_t index=0;index<count;index++){
        const struct kinfo_proc *k=&table[index];pid_t pid=k->kp_proc.p_pid;
        if(selected_count){int hit=0;for(int s=0;s<selected_count;s++)if(selected[s]==pid)hit=1;if(!hit)continue;}
        else if(!everyone&&k->kp_eproc.e_pcred.p_ruid!=me)continue;
        matched++;
        for(int f=0;f<field_count;f++){
            int last=f==field_count-1;char text[8192];
            switch(fields[f].kind){
            case F_PID:printf("%5d",(int)pid);break;
            case F_PPID:printf("%5d",(int)k->kp_eproc.e_ppid);break;
            case F_PGID:printf("%5d",(int)k->kp_eproc.e_pgid);break;
            case F_UID:printf("%5u",(unsigned)k->kp_eproc.e_ucred.cr_uid);break;
            case F_USER:{struct passwd *p=getpwuid(k->kp_eproc.e_ucred.cr_uid);
                if(p)snprintf(text,sizeof(text),"%s",p->pw_name);else snprintf(text,sizeof(text),"%u",(unsigned)k->kp_eproc.e_ucred.cr_uid);
                printf(last?"%s":"%-16s",text);break;}
            case F_COMM:{char path[PROC_PIDPATHINFO_MAXSIZE];
                if(proc_pidpath(pid,path,sizeof(path))<=0)snprintf(path,sizeof(path),"%s",k->kp_proc.p_comm);
                printf(last?"%s":"%-16s",path);break;}
            default:command_line(pid,k->kp_proc.p_comm,text,sizeof(text));printf(last?"%s":"%-16s",text);break;
            }
            putchar(last?'\n':' ');
        }
    }
    free(table);
    return selected_count&&!matched?1:0;
}
