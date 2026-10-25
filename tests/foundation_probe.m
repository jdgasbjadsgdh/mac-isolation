#import <Foundation/Foundation.h>
int main(int argc,char **argv){@autoreleasepool{
    puts("BEFORE_LOCALE");fflush(stdout);
    NSLog(@"languages=%@ locale=%@",[NSLocale preferredLanguages],[[NSLocale currentLocale] localeIdentifier]);
    puts("BEFORE_PATHS");fflush(stdout);
    NSLog(@"support=%@",NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES));
    NSLog(@"arguments=%@",[[NSProcessInfo processInfo] arguments]);
    puts("OK");return 0;
}}
