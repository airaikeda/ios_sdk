//
//  AdjustIo.m
//  AdjustIo
//
//  Created by Christian Wellenbrock on 23.07.12.
//  Copyright (c) 2012 adeven. All rights reserved.
//

#import "AdjustIo.h"
#import "AIApiClient.h"

#import "UIDevice+AIAdditions.h"
#import "NSString+AIAdditions.h"
#import "NSData+AIAdditions.h"
#import "NSMutableDictionary+AIAdditions.h"


static const double kTimerInterval   = 5.0; // TODO: 60 seconds
static const double kSessionInterval = 1.0; // TODO: 30 minutes

static NSString * const kDefaultsKeyLastActivity        = @"lastactivity"; // TODO: rename
static NSString * const kDefaultsKeyLastSessionStart    = @"lastsessionstart";
static NSString * const kDefaultsKeyLastSubsessionStart = @"lastsubsessionstart";
static NSString * const kDefaultsKeySessionCount        = @"sessioncount";
static NSString * const kDefaultsKeySubsessionCount     = @"subsessioncount";
static NSString * const kDefaultsKeyTimeSpent           = @"timespent";
static NSString * const kDefaultsKeyEventCount          = @"eventcount";
static NSString * const kDefaultsKeyPackageQueue        = @"packagequeue";

static NSString * const kPackageKeyPath       = @"path";
static NSString * const kPackageKeyKind       = @"kind";
static NSString * const kPackageKeySuffix     = @"suffix";
static NSString * const kPackageKeyParameters = @"parameters";

static NSString * const kFieldAppToken        = @"app_token";
static NSString * const kFieldMacShortMd5     = @"mac";
static NSString * const kFieldMacSha1         = @"mac_sha1";
static NSString * const kFieldIdfa            = @"idfa";
static NSString * const kFieldFbAttributionId = @"fb_id";
static NSString * const kFieldCreatedAt       = @"created_at";
static NSString * const kFieldSessionLength   = @"session_length";
static NSString * const kFieldSessionCount    = @"session_id";
static NSString * const kFieldSubsessionCount = @"subsession_count";
static NSString * const kFieldLastInterval    = @"last_interval";
static NSString * const kFieldTimeSpent       = @"time_spent";
static NSString * const kFieldEventToken      = @"event_id";
static NSString * const kFieldEventCount      = @"event_count";
static NSString * const kFieldAmount          = @"amount";


static AIApiClient *aiApiClient  = nil;
static AELogger    *aiLogger     = nil;
static NSTimer     *aiTimer      = nil;
static NSLock      *trackingLock = nil;
static NSLock      *defaultsLock = nil;

static NSString *aiAppToken         = nil;
static NSString *aiMacSha1          = nil;
static NSString *aiMacShortMd5      = nil;
static NSString *aiIdForAdvertisers = nil;
static NSString *aiFbAttributionId  = nil;


#pragma mark private interface
@interface AdjustIo()

+ (void)addNotificationObserver;
+ (void)removeNotificationObserver;

+ (void)startTimer;
+ (void)stopTimer;
+ (void)timerFired:(NSTimer *)timer;

+ (void)trackSessionStart;
+ (void)trackSessionEnd;
+ (void)trackEventPackage:(NSMutableDictionary *)event;

+ (void)handleFirstSession;
+ (void)handleNewSession;
+ (void)handleNewSubsession;

+ (void)enqueueTrackingPackage:(NSDictionary *)package;
+ (void)trackFirstPackage;
+ (void)removeFirstPackage:(NSDictionary *)package;
+ (void)trackingPackageSucceeded:(NSDictionary *)package;
+ (void)trackingPackageFailed:(NSDictionary *)package response:(NSString *)response error:(NSError *)error;

+ (NSMutableDictionary *)sessionPackage;
+ (NSMutableDictionary *)eventPackageWithToken:(NSString *)eventToken parameters:(NSDictionary *)parameters;
+ (NSMutableDictionary *)revenuePackageWithToken:(NSString *)eventToken parameters:(NSDictionary *)parameters amount:(float)amount;

+ (BOOL)checkAppToken;
+ (BOOL)checkEventTokenNotNil:(NSString *)eventToken;
+ (BOOL)checkEventTokenLength:(NSString *)eventToken;
+ (BOOL)checkAmount:(float)amount;

@end


#pragma mark AdjustIo
@implementation AdjustIo

#pragma mark public

+ (void)appDidLaunch:(NSString *)yourAppToken {
    if (yourAppToken.length == 0) {
        [aiLogger error:@"Missing App Token."];
        return;
    }

    NSString *macAddress = UIDevice.currentDevice.aiMacAddress;

    aiAppToken         = yourAppToken;
    aiMacSha1          = macAddress.aiSha1;
    aiMacShortMd5      = macAddress.aiRemoveColons.aiMd5;
    aiIdForAdvertisers = UIDevice.currentDevice.aiIdForAdvertisers;
    aiFbAttributionId  = UIDevice.currentDevice.aiFbAttributionId;

    [self addNotificationObserver];
}

+ (void)trackEvent:(NSString *)eventToken {
    [self trackEvent:eventToken withParameters:nil];
}

+ (void)trackEvent:(NSString *)eventToken withParameters:(NSDictionary *)parameters {
    if (![self checkEventTokenNotNil:eventToken]) return;
    if (![self checkEventTokenLength:eventToken]) return;
    if (![self checkAppToken]) return;

    NSMutableDictionary *eventPackage = [self eventPackageWithToken:eventToken parameters:parameters];
    [self trackEventPackage:eventPackage];
}

+ (void)trackRevenue:(float)amountInCents {
    [self trackRevenue:amountInCents forEvent:nil];
}

+ (void)trackRevenue:(float)amountInCents forEvent:(NSString *)eventToken {
    [self trackRevenue:amountInCents forEvent:eventToken withParameters:nil];
}

+ (void)trackRevenue:(float)amount forEvent:(NSString *)eventToken withParameters:(NSDictionary *)parameters {
    if (![self checkEventTokenLength:eventToken]) return;
    if (![self checkAmount:amount]) return;
    if (![self checkAppToken]) return;

    NSMutableDictionary *revenueEvent = [self revenuePackageWithToken:eventToken parameters:parameters amount:amount];
    [self trackEventPackage:revenueEvent];
}

+ (void)setLogLevel:(AELogLevel)logLevel {
    aiLogger.logLevel = logLevel;
}

#pragma mark private

+ (void)initialize {
    if (aiLogger == nil) {
        aiLogger = [AELogger loggerWithTag:@"AdjustIo"];
    }
    if (aiApiClient == nil) {
        aiApiClient = [AIApiClient apiClientWithLogger:aiLogger];
    }
    if (trackingLock == nil) {
        trackingLock = [[NSLock alloc] init];
    }
    if (defaultsLock == nil) {
        defaultsLock = [[NSLock alloc] init];
    }
    [self startTimer];
}

+ (void)addNotificationObserver {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    [center addObserver:self
               selector:@selector(trackSessionStart)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(trackSessionEnd)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(removeNotificationObserver)
                   name:UIApplicationWillTerminateNotification
                 object:nil];
}

+ (void)removeNotificationObserver {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}


+ (void)startTimer {
    if (aiTimer != nil) {
        [aiLogger verbose:@"Timer was started already."];
    } else {
        [aiLogger verbose:@"Starting timer."];
        aiTimer = [NSTimer scheduledTimerWithTimeInterval:kTimerInterval
                                                   target:self
                                                 selector:@selector(timerFired:)
                                                 userInfo:nil
                                                  repeats:YES];
    }
}

+ (void)stopTimer {
    if (aiTimer == nil) {
        [aiLogger verbose:@"Timer was stopped already."];
    } else {
        [aiLogger verbose:@"Stopping timer."];
        [aiTimer invalidate];
        aiTimer = nil;
    }
}

+ (void)timerFired:(NSTimer *)timer {
    [aiLogger verbose:@"Timer updating last activity."];

    [defaultsLock lock];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:NSDate.date forKey:kDefaultsKeyLastActivity];
    [defaults synchronize];
    [defaultsLock unlock];
    [self trackFirstPackage];
}

+ (void)trackSessionEnd {
    [aiLogger verbose:@"Session end updating last activity."];

    [defaultsLock lock];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:NSDate.date forKey:kDefaultsKeyLastActivity];
    [defaults synchronize];
    [defaultsLock unlock];
    [self stopTimer];
}

+ (void)trackSessionStart {
    if (![self checkAppToken]) return;

    [self startTimer];

    [defaultsLock lock];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *lastActivity     = [defaults objectForKey:kDefaultsKeyLastActivity];

    if (lastActivity == nil) {
        [self handleFirstSession];
        [defaults synchronize];
        [defaultsLock unlock];
        [self trackFirstPackage];
        return;
    }

    NSDate *now = NSDate.date;
    double lastInterval = [now timeIntervalSinceDate:lastActivity];
    if (lastInterval > kSessionInterval) {
        [self handleNewSession];
        [defaults synchronize];
        [defaultsLock unlock];
        [self trackFirstPackage];
        return;

    } else {
        [self handleNewSubsession];
        [defaults synchronize];
        [defaultsLock unlock];
        return;
    }
}


+ (void)trackEventPackage:(NSMutableDictionary *)eventPackage {
    NSDate *now = NSDate.date;

    [defaultsLock lock];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *lastSessionStart = [defaults objectForKey:kDefaultsKeyLastSessionStart];
    int     sessionCount     = [defaults integerForKey:kDefaultsKeySessionCount];
    int     eventCount       = [defaults integerForKey:kDefaultsKeyEventCount];
    double  sessionLength    = [now timeIntervalSinceDate:lastSessionStart];

    eventCount++;

    NSMutableDictionary *eventParameters = [eventPackage objectForKey:kPackageKeyParameters];
    [eventParameters setInteger:eventCount    forKey:kFieldEventCount];
    [eventParameters setInteger:sessionCount  forKey:kFieldSessionCount];
    [eventParameters setInteger:sessionLength forKey:kFieldSessionLength];
    [self enqueueTrackingPackage:eventPackage];

    [defaults setInteger:eventCount forKey:kDefaultsKeyEventCount];
    [defaults setObject:now         forKey:kDefaultsKeyLastActivity];
    [defaults synchronize];
    [defaultsLock unlock];

    [self trackFirstPackage];
}

+ (void)handleFirstSession {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *now = NSDate.date;

    NSMutableDictionary *sessionPackage    = [self sessionPackage];
    NSMutableDictionary *sessionParameters = [sessionPackage objectForKey:kPackageKeyParameters];
    [sessionParameters setObject:now forKey:kFieldCreatedAt];
    [sessionParameters setInteger:1  forKey:kFieldSessionCount];
    [self enqueueTrackingPackage:sessionPackage];

    [defaults setInteger:1  forKey:kDefaultsKeySessionCount];
    [defaults setInteger:1  forKey:kDefaultsKeySubsessionCount];
    [defaults setObject:now forKey:kDefaultsKeyLastSessionStart];
    [defaults setObject:now forKey:kDefaultsKeyLastSubsessionStart];
    [defaults setObject:now forKey:kDefaultsKeyLastActivity];
    [defaults setDouble:0   forKey:kDefaultsKeyTimeSpent];
}

+ (void)handleNewSession {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *now = NSDate.date;

    int     sessionCount        = [defaults integerForKey:kDefaultsKeySessionCount] + 1;
    int     subsessionCount     = [defaults integerForKey:kDefaultsKeySubsessionCount];
    NSDate *lastSessionStart    = [defaults objectForKey:kDefaultsKeyLastSessionStart];
    NSDate *lastSubsessionStart = [defaults objectForKey:kDefaultsKeyLastSubsessionStart];
    NSDate *lastActivity        = [defaults objectForKey:kDefaultsKeyLastActivity];
    double  timeSpent           = [defaults doubleForKey:kDefaultsKeyTimeSpent];
    double  sessionLength       = [lastActivity timeIntervalSinceDate:lastSessionStart];
    double  lastTimeSpent       = [lastActivity timeIntervalSinceDate:lastSubsessionStart];
    double  lastInterval        = [now timeIntervalSinceDate:lastActivity];

    timeSpent += lastTimeSpent;

    NSMutableDictionary *sessionPackage    = [self sessionPackage];
    NSMutableDictionary *sessionParameters = [sessionPackage objectForKey:kPackageKeyParameters];
    [sessionParameters setDate:now                     forKey:kFieldCreatedAt];
    [sessionParameters setInteger:sessionCount         forKey:kFieldSessionCount];
    [sessionParameters setInteger:subsessionCount      forKey:kFieldSubsessionCount];
    [sessionParameters setInteger:round(lastInterval)  forKey:kFieldLastInterval];
    [sessionParameters setInteger:round(sessionLength) forKey:kFieldSessionLength];
    [sessionParameters setInteger:round(timeSpent)     forKey:kFieldTimeSpent];
    [self enqueueTrackingPackage:sessionPackage];

    [defaults setInteger:sessionCount forKey:kDefaultsKeySessionCount];
    [defaults setInteger:1            forKey:kDefaultsKeySubsessionCount];
    [defaults setObject:now           forKey:kDefaultsKeyLastSessionStart];
    [defaults setObject:now           forKey:kDefaultsKeyLastSubsessionStart];
    [defaults setObject:now           forKey:kDefaultsKeyLastActivity];
    [defaults setDouble:0             forKey:kDefaultsKeyTimeSpent];
}

+ (void)handleNewSubsession {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *now = NSDate.date;

    int     subsessionCount     = [defaults integerForKey:kDefaultsKeySubsessionCount] + 1;
    NSDate *lastSubsessionStart = [defaults objectForKey:kDefaultsKeyLastSubsessionStart];
    NSDate *lastActivity        = [defaults objectForKey:kDefaultsKeyLastActivity];
    double  timeSpent           = [defaults doubleForKey:kDefaultsKeyTimeSpent];

    double lastTimeSpent = [lastActivity timeIntervalSinceDate:lastSubsessionStart];
    timeSpent += lastTimeSpent;

    [defaults setInteger:subsessionCount forKey:kDefaultsKeySubsessionCount];
    [defaults setObject:now              forKey:kDefaultsKeyLastSubsessionStart];
    [defaults setObject:now              forKey:kDefaultsKeyLastActivity];
    [defaults setDouble:timeSpent        forKey:kDefaultsKeyTimeSpent];

    [aiLogger verbose:@"Subsession %d adds time spent %f.", subsessionCount, lastTimeSpent];
}

// TODO: in background?
+ (void)enqueueTrackingPackage:(NSDictionary *)package {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *packageQueue = [defaults objectForKey:kDefaultsKeyPackageQueue];

    NSMutableArray *mutableQueue;
    if (packageQueue != nil) {
        mutableQueue = [NSMutableArray arrayWithArray:packageQueue];
    } else {
        mutableQueue = [NSMutableArray array];
    }

    [mutableQueue addObject:package];
    [defaults setObject:mutableQueue forKey:kDefaultsKeyPackageQueue];

    NSString *kind = [package objectForKey:kPackageKeyKind];
    int packageCount = mutableQueue.count;
    if (packageCount > 1) {
        [aiLogger info:@"Added %@ package to tracking queue at position %d.", kind, packageCount];
    } else {
        [aiLogger debug:@"Added %@ package to tracking queue.", kind];
    }
}

+ (void)trackFirstPackage {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *packageQueue = [defaults objectForKey:kDefaultsKeyPackageQueue];
    if (packageQueue == nil || packageQueue.count == 0) {
        return;
    }

    if (![trackingLock tryLock]) {
        return;
    }

    NSDictionary *package = [packageQueue objectAtIndex:0];
    NSString     *path    = [package objectForKey:kPackageKeyPath];
    NSDictionary *params  = [package objectForKey:kPackageKeyParameters];

    void (^success)(AFHTTPRequestOperation *operation, id responseObject) =
    ^(AFHTTPRequestOperation *operation, id responseObject) {
        [self trackingPackageSucceeded:package];
    };

    void (^failure)(AFHTTPRequestOperation *operation, NSError *error) =
    ^(AFHTTPRequestOperation *operation, NSError *error) {
        [self trackingPackageFailed:package response:operation.responseString error:error];
    };

    [aiApiClient postPath:path parameters:params success:success failure:failure];
}

// TODO: in background?
+ (void)removeFirstPackage:(NSDictionary *)package {
    [defaultsLock lock];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *packageQueue = [defaults objectForKey:kDefaultsKeyPackageQueue];
    NSMutableArray *mutableQueue = [NSMutableArray arrayWithArray:packageQueue];
    [mutableQueue removeObjectAtIndex:0];
    [defaults setObject:mutableQueue forKey:kDefaultsKeyPackageQueue];
    [defaults synchronize];
    [defaultsLock unlock];
}

+ (void)trackingPackageSucceeded:(NSDictionary *)package {
    NSString     *kind   = [package objectForKey:kPackageKeyKind];
    NSString     *suffix = [package objectForKey:kPackageKeySuffix];
    NSDictionary *params = [package objectForKey:kPackageKeyParameters];

    [aiLogger info:@"Tracked %@%@", kind, suffix];
    [aiLogger verbose:@"Request parameters: %@", params];

    [self removeFirstPackage:package];
    [trackingLock unlock];

    if (!aiTimer.isValid) {
        return; // stop tracking after session end
    }

    [self trackFirstPackage];
}

+ (void)trackingPackageFailed:(NSDictionary *)package response:(NSString *)response error:(NSError *)error {
    NSString *kind    = [package objectForKey:kPackageKeyKind];
    NSString *suffix  = [package objectForKey:kPackageKeySuffix];
    NSString *message = [NSString stringWithFormat:@"Failed to track %@%@", kind, suffix];

    if (response == nil || response.length == 0) {
        [trackingLock unlock];
        [aiLogger debug:@"%@ (%@ Will retry later)", message, error.localizedDescription];
        return;
    }

    NSDictionary *params = [package objectForKey:kPackageKeyParameters];
    [aiLogger warn:@"%@ (%@)", message, response.aiTrim];
    [aiLogger verbose:@"Request parameters: %@", params];

    [self removeFirstPackage:package];
    [trackingLock unlock];
    [self trackFirstPackage];
}

+ (NSMutableDictionary *)sessionPackage {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    [params setObject:aiAppToken         forKey:kFieldAppToken];
    [params setObject:aiMacShortMd5      forKey:kFieldMacShortMd5];
    [params setObject:aiIdForAdvertisers forKey:kFieldIdfa];
    [params setObject:aiMacSha1          forKey:kFieldMacSha1];
    [params setObject:aiFbAttributionId  forKey:kFieldFbAttributionId];

    NSMutableDictionary *sessionPackage = [NSMutableDictionary dictionary];
    [sessionPackage setObject:@"/startup" forKey:kPackageKeyPath];
    [sessionPackage setObject:@"session"  forKey:kPackageKeyKind];
    [sessionPackage setObject:@"."        forKey:kPackageKeySuffix];
    [sessionPackage setObject:params      forKey:kPackageKeyParameters];

    return sessionPackage;
}

+ (NSMutableDictionary *)eventPackageWithToken:(NSString *)eventToken parameters:(NSDictionary *)callbackParams {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    [params setObject:aiAppToken         forKey:kFieldAppToken];
    [params setObject:aiMacShortMd5      forKey:kFieldMacShortMd5];
    [params setObject:aiIdForAdvertisers forKey:kFieldIdfa];
    [params setObject:eventToken         forKey:kFieldEventToken];

    if (callbackParams != nil) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:callbackParams options:0 error:nil];
        NSString *paramString = jsonData.aiEncodeBase64;
        [params setValue:paramString forKey:kPackageKeyParameters];
    }

    NSString *suffix = [NSString stringWithFormat:@" '%@'.", eventToken];
    NSMutableDictionary *eventPackage = [NSMutableDictionary dictionary];
    [eventPackage setObject:@"/event"  forKey:kPackageKeyPath];
    [eventPackage setObject:@"event"   forKey:kPackageKeyKind];
    [eventPackage setObject:suffix     forKey:kPackageKeySuffix];
    [eventPackage setObject:params     forKey:kPackageKeyParameters];

    return eventPackage;
}

+ (NSMutableDictionary *)revenuePackageWithToken:(NSString *)eventToken parameters:(NSDictionary *)callbackParams amount:(float)amount {
    NSString *amountInMillis = [NSNumber numberWithInt:roundf(10 * amount)].stringValue;

    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    [params setObject:aiAppToken         forKey:kFieldAppToken];
    [params setObject:aiMacShortMd5      forKey:kFieldMacShortMd5];
    [params setObject:aiIdForAdvertisers forKey:kFieldIdfa];
    [params setObject:amountInMillis     forKey:kFieldAmount];
    [params trySetObject:eventToken      forKey:kFieldEventToken];

    if (callbackParams != nil) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:callbackParams options:0 error:nil];
        NSString *paramString = jsonData.aiEncodeBase64;
        [params setValue:paramString forKey:kPackageKeyParameters];
    }

    NSString *suffix = [NSString stringWithFormat:@": %.1f Cent", amount];

    if (eventToken != nil) {
        suffix = [NSString stringWithFormat:@"%@ (event '%@')", suffix, eventToken];
    }

    NSMutableDictionary *eventPackage = [NSMutableDictionary dictionary];
    [eventPackage setObject:@"/revenue" forKey:kPackageKeyPath];
    [eventPackage setObject:@"revenue"  forKey:kPackageKeyKind];
    [eventPackage setObject:suffix      forKey:kPackageKeySuffix];
    [eventPackage setObject:params      forKey:kPackageKeyParameters];

    return eventPackage;
}

+ (BOOL)checkAppToken {
    if (aiAppToken == nil) {
        [aiLogger error:@"Missing App Token."];
        return NO;
    } else if (aiAppToken.length != 12) {
        [aiLogger error:@"Malformed App Token %@", aiAppToken];
        return NO;
    }
    return YES;
}

+ (BOOL)checkEventTokenNotNil:(NSString *)eventToken {
    if (eventToken == nil) {
        [aiLogger error:@"Missing Event Token"];
        return NO;
    }
    return YES;
}

+ (BOOL)checkEventTokenLength:(NSString *)eventToken {
    if (eventToken == nil) {
        return YES;
    }
    if (eventToken.length != 6) {
        [aiLogger error:@"Malformed Event Token '%@'", eventToken];
        return NO;
    }
    return YES;
}

+ (BOOL)checkAmount:(float)amount {
    if (amount <= 0.0f) {
        [aiLogger error:@"Invalid amount %.1f", amount];
        return NO;
    }
    return YES;
}

@end
