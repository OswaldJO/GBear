#import "GBearStreamContext.h"

@implementation GBearStreamContext

+ (instancetype)shared {
    static GBearStreamContext *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[GBearStreamContext alloc] init];
    });
    return instance;
}

@end
