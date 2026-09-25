#import "Utils.h"

NS_ASSUME_NONNULL_BEGIN

@interface TemporaryHost : NSObject

@property (atomic) State state;
@property (atomic) PairState pairState;
@property (atomic, nullable, retain) NSString *activeAddress;
@property (atomic, nullable, retain) NSString *currentGame;
@property (atomic) unsigned short httpsPort;
@property (atomic) BOOL isNvidiaServerSoftware;
@property (atomic, nullable, retain) NSData *serverCert;
@property (atomic, nullable, retain) NSString *address;
@property (atomic, nullable, retain) NSString *externalAddress;
@property (atomic, nullable, retain) NSString *localAddress;
@property (atomic, nullable, retain) NSString *ipv6Address;
@property (atomic, nullable, retain) NSString *mac;
@property (atomic) int serverCodecModeSupport;
@property (atomic, retain) NSString *name;
@property (atomic, retain) NSString *uuid;
@property (atomic, retain) NSSet *appList;

@end

NS_ASSUME_NONNULL_END
