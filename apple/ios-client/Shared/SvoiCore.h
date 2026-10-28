#import <Foundation/Foundation.h>
#include <stdint.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *SvoiCoreOpen(NSString *directory);
FOUNDATION_EXPORT NSString *SvoiCoreRequest(NSString *method, NSString *path, NSString *token, NSString *body);
FOUNDATION_EXPORT NSString *SvoiCoreConfig(NSString *token, NSString *serverID);
FOUNDATION_EXPORT NSString *SvoiCoreProbe(NSString *token, NSString *serverID, NSString *requestID);
FOUNDATION_EXPORT void SvoiCoreCancelProbe(NSString *requestID);
FOUNDATION_EXPORT void SvoiCoreCancelSpeed(void);
FOUNDATION_EXPORT NSString *SvoiCoreStart(NSString *config, int32_t descriptor, NSString *assets);
FOUNDATION_EXPORT NSString *SvoiCoreStop(void);
FOUNDATION_EXPORT NSString *SvoiCoreVersion(void);
NS_ASSUME_NONNULL_END
