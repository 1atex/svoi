#import "SvoiCore.h"
#import <SvoiMobile/SvoiMobile.h>

static SvoiMobileSession *session;
static NSMutableDictionary<NSString *, SvoiMobileProbeRequest *> *probes;
static NSMutableSet<NSString *> *cancelled;

static NSString *encode(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
static NSString *failure(NSError *error) {
    return encode(@{@"status": @400, @"body": @{@"error": error.localizedDescription ?: @"Ошибка ядра"}});
}
NSString *SvoiCoreOpen(NSString *directory) {
    @synchronized([SvoiMobileSession class]) {
        if (session) return @"";
        NSError *error = nil;
        session = SvoiMobileNewSession(directory, &error);
        probes = [NSMutableDictionary dictionary];
        cancelled = [NSMutableSet set];
        return session ? @"" : (error.localizedDescription ?: @"Не удалось открыть данные SVOI");
    }
}
NSString *SvoiCoreRequest(NSString *method, NSString *path, NSString *token, NSString *body) {
    if (!session) return failure([NSError errorWithDomain:@"SVOI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Ядро не запущено"}]);
    return [session request:method path:[@"/api/" stringByAppendingString:path] token:token body:body];
}
NSString *SvoiCoreConfig(NSString *token, NSString *serverID) {
    NSError *error = nil;
    NSString *config = [session appleConfig:token serverID:serverID error:&error];
    return error ? failure(error) : encode(@{@"status": @200, @"body": @{@"config": config}});
}
NSString *SvoiCoreProbe(NSString *token, NSString *serverID, NSString *requestID) {
    SvoiMobileProbeRequest *probe;
    @synchronized([SvoiMobileSession class]) {
        if ([cancelled containsObject:requestID]) {
            [cancelled removeObject:requestID];
            return failure([NSError errorWithDomain:@"SVOI" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Проверка отменена"}]);
        }
        if (!session || probes.count >= 2) return failure([NSError errorWithDomain:@"SVOI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Дождитесь завершения предыдущих проверок"}]);
        probe = [session newProbe:token serverID:serverID];
        probes[requestID] = probe;
    }
    NSError *error = nil;
    int64_t latency = 0;
    [probe run:&latency error:&error];
    @synchronized([SvoiMobileSession class]) { [probes removeObjectForKey:requestID]; }
    return error ? failure(error) : encode(@{@"status": @200, @"body": @{@"latency": @(latency)}});
}
void SvoiCoreCancelProbe(NSString *requestID) {
    @synchronized([SvoiMobileSession class]) {
        [probes[requestID] cancel];
        [cancelled addObject:requestID];
        if (cancelled.count > 128) [cancelled removeObject:cancelled.anyObject];
    }
}
NSString *SvoiCoreStart(NSString *config, int32_t descriptor, NSString *assets) {
    NSError *error = nil;
    SvoiMobileStartApple(config, descriptor, assets, &error);
    return error.localizedDescription ?: @"";
}
NSString *SvoiCoreStop(void) {
    NSError *error = nil;
    SvoiMobileStop(&error);
    return error.localizedDescription ?: @"";
}
NSString *SvoiCoreVersion(void) { return SvoiMobileVersion(); }
