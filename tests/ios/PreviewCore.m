#import "SvoiCore.h"

static NSString *unavailable(void) { return @"{\"status\":400,\"body\":{\"error\":\"UI preview: native VPN is not linked\"}}"; }
NSString *SvoiCoreOpen(NSString *directory) { return @"UI preview only"; }
NSString *SvoiCoreRequest(NSString *method, NSString *path, NSString *token, NSString *body) { return unavailable(); }
NSString *SvoiCoreConfig(NSString *token, NSString *serverID) { return unavailable(); }
NSString *SvoiCoreProbe(NSString *token, NSString *serverID, NSString *requestID) { return unavailable(); }
void SvoiCoreCancelProbe(NSString *requestID) {}
NSString *SvoiCoreStart(NSString *config, int32_t descriptor, NSString *assets) { return @"UI preview only"; }
NSString *SvoiCoreStop(void) { return @""; }
NSString *SvoiCoreVersion(void) { return @"UI preview"; }
