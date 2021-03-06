//
//  AVIMWebSocketWrapper.m
//  AVOSCloudIM
//
//  Created by Qihe Bian on 12/4/14.
//  Copyright (c) 2014 LeanCloud Inc. All rights reserved.
//

#import "AVOSCloudIM.h"
#import "AVIMWebSocketWrapper.h"
#import "LCRTMWebSocket.h"
#import "AVIMErrorUtil.h"
#import "AVIMCommon_Internal.h"
#import "AVIMClient_Internal.h"

#import "LCNetworkReachabilityManager.h"
#import "AVPaasClient.h"
#import "LCRouter_Internal.h"
#import "AVErrorUtils.h"
#import "AVUtils.h"

#import "AVIMGenericCommand+AVIMMessagesAdditions.h"
#import <TargetConditionals.h>

#define LCIM_OUT_COMMAND_LOG_FORMAT \
    @"\n------ BEGIN LeanCloud IM Out Command ------\n" \
    @"content: %@\n"                                  \
    @"------ END ---------------------------------" \

#define LCIM_IN_COMMAND_LOG_FORMAT \
    @"\n------ BEGIN LeanCloud IM In Command ------\n" \
    @"content: %@\n"                                 \
    @"------ END --------------------------------"

// 180s
#define PingInterval (60.0 * 3.0)
// 20s
#define PingTimeout (PingInterval / 9.0)
// 10s
#define PingLeeway (PingTimeout / 2.0)

static NSTimeInterval AVIMWebSocketDefaultTimeoutInterval = 30.0;
static NSString * const AVIMProtocolPROTOBUF1 = @"lc.protobuf2.1";
static NSString * const AVIMProtocolPROTOBUF2 = @"lc.protobuf2.2";
static NSString * const AVIMProtocolPROTOBUF3 = @"lc.protobuf2.3";

// MARK: - LCIMProtobufCommandWrapper

@interface LCIMProtobufCommandWrapper () {
    NSError *_error;
    BOOL _hasDecodedError;
}

@property (nonatomic, copy) void (^callback)(LCIMProtobufCommandWrapper *commandWrapper);
@property (nonatomic, assign) uint16_t index;
@property (nonatomic, assign) NSTimeInterval deadlineTimestamp;

@end

@implementation LCIMProtobufCommandWrapper

- (instancetype)init
{
    self = [super init];
    if (self) {
        self->_hasDecodedError = false;
    }
    return self;
}

- (BOOL)hasCallback
{
    return self->_callback ? true : false;
}

- (void)executeCallbackAndSetItToNil
{
    if (self->_callback) {
        self->_callback(self);
        // set to nil to avoid cycle retain
        self->_callback = nil;
    }
}

- (void)setError:(NSError *)error
{
    self->_error = error;
}

- (NSError *)error
{
    if (self->_error) {
        return self->_error;
    }
    else if (self->_inCommand && !self->_hasDecodedError) {
        self->_hasDecodedError = true;
        self->_error = [self decodingError:self->_inCommand];
        return self->_error;
    }
    return nil;
}

- (NSError *)decodingError:(AVIMGenericCommand *)command
{
    int32_t code = 0;
    NSString *reason = nil;
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    
    AVIMErrorCommand *errorCommand = (command.hasErrorMessage ? command.errorMessage : nil);
    AVIMSessionCommand *sessionCommand = (command.hasSessionMessage ? command.sessionMessage : nil);
    AVIMAckCommand *ackCommand = (command.hasAckMessage ? command.ackMessage : nil);
    
    if (errorCommand && errorCommand.hasCode) {
        code = errorCommand.code;
        reason = (errorCommand.hasReason ? errorCommand.reason : nil);
        if (errorCommand.hasAppCode) {
            userInfo[keyPath(errorCommand, appCode)] = @(errorCommand.appCode);
        }
        if (errorCommand.hasDetail) {
            userInfo[keyPath(errorCommand, detail)] = errorCommand.detail;
        }
    }
    else if (sessionCommand && sessionCommand.hasCode) {
        code = sessionCommand.code;
        reason = (sessionCommand.hasReason ? sessionCommand.reason : nil);
        if (sessionCommand.hasDetail) {
            userInfo[keyPath(sessionCommand, detail)] = sessionCommand.detail;
        }
    }
    else if (ackCommand && ackCommand.hasCode) {
        code = ackCommand.code;
        reason = (ackCommand.hasReason ? ackCommand.reason : nil);
        if (ackCommand.hasAppCode) {
            userInfo[keyPath(ackCommand, appCode)] = @(ackCommand.appCode);
        }
    }
    
    return (code > 0) ? LCError(code, reason, userInfo) : nil;
}

@end

// MARK: - AVIMWebSocketWrapper

@interface AVIMWebSocketWrapper () <LCRTMWebSocketDelegate>

@property (atomic, assign) BOOL isApplicationInBackground;
@property (atomic, assign) LCNetworkReachabilityStatus currentNetworkReachabilityStatus;
@property (nonatomic) BOOL isWebSocketOpened;

@end

@implementation AVIMWebSocketWrapper {
    
    __weak id<AVIMWebSocketWrapperDelegate> _delegate;
    
    NSTimeInterval _commandTimeToLive;
    uint16_t _serialIndex;
    BOOL _activatingReconnection;
    BOOL _useSecondaryServer;
    
    void (^_openCallback)(BOOL, NSError *);
    NSMutableDictionary<NSNumber *, LCIMProtobufCommandWrapper *> *_commandWrapperMap;
    NSMutableArray<NSNumber *> *_serialIndexArray;
    
    dispatch_queue_t _internalSerialQueue;
    
    dispatch_source_t _pingSenderTimerSource;
    NSTimeInterval _lastPingTimestamp;
    NSTimeInterval _lastPingSenderEventTimestamp;
    BOOL _didReceivePong;
    
    dispatch_source_t _timeoutCheckerTimerSource;
    
    LCRTMWebSocket *_websocket;
    LCNetworkReachabilityManager *_reachabilityMonitor;
    BOOL _didInitNetworkReachabilityStatus;
    
    dispatch_block_t _openTimeoutBlock;
}

+ (void)setTimeoutIntervalInSeconds:(NSTimeInterval)seconds
{
    if (seconds > 0) {
        AVIMWebSocketDefaultTimeoutInterval = seconds;
    }
}

- (instancetype)initWithDelegate:(id<AVIMWebSocketWrapperDelegate>)delegate
{
    self = [super init];
    if (self) {
#if DEBUG
        NSParameterAssert([delegate respondsToSelector:@selector(webSocketWrapper:didReceiveCommand:)]);
        NSParameterAssert([delegate respondsToSelector:@selector(webSocketWrapper:didReceiveCommandCallback:)]);
        NSParameterAssert([delegate respondsToSelector:@selector(webSocketWrapper:didCommandEncounterError:)]);
#endif
        self->_delegate = delegate;
        self->_commandTimeToLive = AVIMWebSocketDefaultTimeoutInterval;
        self->_serialIndex = 1;
        self->_activatingReconnection = false;
        self->_useSecondaryServer = false;
        
        self->_openCallback = nil;
        self->_commandWrapperMap = [NSMutableDictionary dictionary];
        self->_serialIndexArray = [NSMutableArray array];
        
        self->_internalSerialQueue = ({
            NSString *className = NSStringFromClass(self.class);
            NSString *ivarName = ivarName(self, _internalSerialQueue);
            NSString *label = [NSString stringWithFormat:@"%@.%@", className, ivarName];
            dispatch_queue_t queue = dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);
#ifdef DEBUG
            void *key = (__bridge void *)queue;
            dispatch_queue_set_specific(queue, key, key, NULL);
#endif
            queue;
        });
        
        self->_pingSenderTimerSource = nil;
        self->_lastPingSenderEventTimestamp = 0;
        self->_lastPingTimestamp = 0;
        self->_didReceivePong = false;
        
        self->_timeoutCheckerTimerSource = nil;
        
        self->_websocket = nil;
        self->_openTimeoutBlock = nil;
        
#if TARGET_OS_IOS
        self->_isApplicationInBackground = (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground);
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
#endif
        
        __weak typeof(self) weakSelf = self;
        self->_reachabilityMonitor = [LCNetworkReachabilityManager manager];
        self->_reachabilityMonitor.reachabilityQueue = self->_internalSerialQueue;
        self->_currentNetworkReachabilityStatus = self->_reachabilityMonitor.networkReachabilityStatus;
        self->_didInitNetworkReachabilityStatus = false;
        [self->_reachabilityMonitor setReachabilityStatusChangeBlock:^(LCNetworkReachabilityStatus newStatus) {
            AVIMWebSocketWrapper *strongSelf = weakSelf;
            if (!strongSelf) { return; }
            AVLoggerInfo(AVLoggerDomainIM, @"<websocket wrapper address: %p> network reachability status: %@.", strongSelf, @(newStatus));
            LCNetworkReachabilityStatus oldStatus = strongSelf.currentNetworkReachabilityStatus;
            strongSelf.currentNetworkReachabilityStatus = newStatus;
            if (strongSelf->_didInitNetworkReachabilityStatus) {
                if (oldStatus != LCNetworkReachabilityStatusNotReachable && newStatus == LCNetworkReachabilityStatusNotReachable) {
                    NSError *error = ({
                        AVIMErrorCode code = AVIMErrorCodeConnectionLost;
                        NSString *reason = @"Due to network unavailable, connection lost.";
                        LCError(code, reason, nil);
                    });
                    [strongSelf purgeWithError:error];
                    [strongSelf pauseWithError:error];
                } else if (oldStatus != newStatus && newStatus != LCNetworkReachabilityStatusNotReachable) {
                    NSError *error = ({
                        AVIMErrorCode code = AVIMErrorCodeConnectionLost;
                        NSString *reason = @"Due to network interface did change, connection lost.";
                        LCError(code, reason, nil);
                    });
                    [strongSelf purgeWithError:error];
                    [strongSelf pauseWithError:error];
                    [strongSelf tryConnecting:false];
                }
            } else {
                strongSelf->_didInitNetworkReachabilityStatus = true;
            }
        }];
        [self->_reachabilityMonitor startMonitoring];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self->_reachabilityMonitor stopMonitoring];
    [self->_websocket safeClean];
}

// MARK: - Application Notification

#if TARGET_OS_IOS
- (void)applicationDidEnterBackground
{
    AVLoggerInfo(AVLoggerDomainIM, @"<websocket wrapper address: %p> application did enter background.", self);
    [self handleApplicationStateIsInBackground:true];
}

- (void)applicationWillEnterForeground
{
    AVLoggerInfo(AVLoggerDomainIM, @"<websocket wrapper address: %p> application will enter foreground.", self);
    [self handleApplicationStateIsInBackground:false];
}

- (void)handleApplicationStateIsInBackground:(BOOL)isInBackground
{
    BOOL newStatus = isInBackground;
    BOOL oldStatus = self.isApplicationInBackground;
    self.isApplicationInBackground = newStatus;
    if (newStatus != oldStatus) {
        [self addOperationToInternalSerialQueue:^(AVIMWebSocketWrapper *websocketWrapper) {
            if (isInBackground) {
                NSError *error = ({
                    AVIMErrorCode code = AVIMErrorCodeConnectionLost;
                    NSString *reason = @"Due to application did enter background, connection lost.";
                    LCError(code, reason, nil);
                });
                [websocketWrapper purgeWithError:error];
                [websocketWrapper pauseWithError:error];
            } else {
                [websocketWrapper tryConnecting:false];
            }
        }];
    }
}
#endif

// MARK: - Open & Close

static NSArray<NSString *> * RTMProtocols()
{
    NSMutableSet<NSString *> *protocols = [NSMutableSet set];
    NSDictionary *userOptions = [AVIMClient sessionProtocolOptions];
    NSNumber *useUnread = [NSNumber _lc_decoding:userOptions key:kAVIMUserOptionUseUnread];
    if (useUnread.boolValue) {
        [protocols addObject:AVIMProtocolPROTOBUF3];
    } else {
        [protocols addObject:AVIMProtocolPROTOBUF1];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray *customProtocols = [NSArray _lc_decoding:userOptions key:AVIMUserOptionCustomProtocols];
    if (customProtocols) {
        [protocols removeAllObjects];
        for (NSString *protocol in customProtocols) {
            if ([NSString _lc_is_type_of:protocol]) {
                [protocols addObject:protocol];
            }
        }
    }
#pragma clang diagnostic pop
    return protocols.allObjects;
}

- (void)openWithCallback:(void (^)(BOOL succeeded, NSError *error))callback
{
    [self addOperationToInternalSerialQueue:^(AVIMWebSocketWrapper *websocketWrapper) {
        LCRTMWebSocket *websocket = websocketWrapper->_websocket;
        if (websocket && websocketWrapper.isWebSocketOpened) {
            callback(true, nil);
        } else {
            [websocketWrapper purgeWithError:({
                AVIMErrorCode code = AVIMErrorCodeConnectionLost;
                LCError(code, AVIMErrorMessage(code), nil);
            })];
            websocketWrapper->_openCallback = callback;
            [websocketWrapper tryConnecting:true];
        }
    }];
}

- (void)setActivatingReconnectionEnabled:(BOOL)enabled
{
    [self addOperationToInternalSerialQueue:^(AVIMWebSocketWrapper *websocketWrapper) {
        websocketWrapper->_activatingReconnection = enabled;
    }];
}

- (void)close
{
    [self addOperationToInternalSerialQueue:^(AVIMWebSocketWrapper *websocketWrapper) {
        NSError *error = ({
            AVIMErrorCode code = AVIMErrorCodeConnectionLost;
            LCError(code, @"Connection did close by local peer.", nil);
        });
        [websocketWrapper purgeWithError:error];
        if (websocketWrapper->_openCallback) {
            websocketWrapper->_openCallback(false, error);
            websocketWrapper->_openCallback = nil;
        }
    }];
}

// MARK: - Websocket Open & Close Notification

- (void)LCRTMWebSocket:(LCRTMWebSocket *)socket didOpenWithProtocol:(NSString *)protocol
{
    AssertRunInQueue(self->_internalSerialQueue);
    NSParameterAssert(socket == self->_websocket);
    AVLoggerInfo(AVLoggerDomainIM, @"<address: %p> websocket did open with protocol: %@.", socket, protocol ?: @"nil");
    self.isWebSocketOpened = true;
    if (self->_openTimeoutBlock) {
        dispatch_block_cancel(self->_openTimeoutBlock);
        self->_openTimeoutBlock = nil;
    }
    [self startPingSender];
    [self startTimeoutChecker];
    if (self->_openCallback) {
        self->_openCallback(true, nil);
        self->_openCallback = nil;
    } else {
        id<AVIMWebSocketWrapperDelegate> delegate = self->_delegate;
        if ([delegate respondsToSelector:@selector(webSocketWrapperDidReopen:)]) {
            [delegate webSocketWrapperDidReopen:self];
        }
    }
}

- (void)LCRTMWebSocket:(LCRTMWebSocket *)socket didCloseWithError:(NSError *)error
{
    AssertRunInQueue(self->_internalSerialQueue);
    NSParameterAssert(socket == self->_websocket);
    if (!error) {
        NSString *reason = @"Connection did close by remote peer.";
        error = LCError(AVIMErrorCodeConnectionLost, reason, nil);
    }
    AVLoggerError(AVLoggerDomainIM, @"<address: %p> websocket did disconnect with error: %@.", socket, error);
    self->_useSecondaryServer = !self->_useSecondaryServer;
    [self purgeWithError:error];
    [self pauseWithError:error];
    [self tryConnecting:false];
}

// MARK: - Command Send & Receive

- (void)sendCommandWrapper:(LCIMProtobufCommandWrapper *)commandWrapper
{
    [self addOperationToInternalSerialQueue:^(AVIMWebSocketWrapper *websocketWrapper) {
        if (!commandWrapper || !commandWrapper.outCommand) {
            return;
        }
        LCRTMWebSocket *webSocket = websocketWrapper->_websocket;
        id<AVIMWebSocketWrapperDelegate> delegate = websocketWrapper->_delegate;
        if (!webSocket || !websocketWrapper.isWebSocketOpened) {
            commandWrapper.error = ({
                AVIMErrorCode code = AVIMErrorCodeConnectionLost;
                LCError(code, AVIMErrorMessage(code), nil);
            });
            [delegate webSocketWrapper:websocketWrapper didCommandEncounterError:commandWrapper];
            return;
        }
        if ([commandWrapper hasCallback]) {
            uint16_t index = [websocketWrapper serialIndex];
            commandWrapper.index = index;
            commandWrapper.outCommand.i = index;
        }
        NSData *data = [commandWrapper.outCommand data];
        if (data.length > 5000) {
            commandWrapper.error = ({
                AVIMErrorCode code = AVIMErrorCodeCommandDataLengthTooLong;
                LCError(code, AVIMErrorMessage(code), nil);
            });
            [delegate webSocketWrapper:websocketWrapper didCommandEncounterError:commandWrapper];
            return;
        }
        if (commandWrapper.index) {
            commandWrapper.deadlineTimestamp = NSDate.date.timeIntervalSince1970 + websocketWrapper->_commandTimeToLive;
            NSNumber *index = @(commandWrapper.index);
            websocketWrapper->_commandWrapperMap[index] = commandWrapper;
            [websocketWrapper->_serialIndexArray addObject:index];
        }
        [webSocket sendMessage:[LCRTMWebSocketMessage messageWithData:data] completion:^{
            AVLoggerInfo(AVLoggerDomainIM, LCIM_OUT_COMMAND_LOG_FORMAT, [commandWrapper.outCommand avim_description]);
        }];
    }];
}

- (void)LCRTMWebSocket:(LCRTMWebSocket *)socket didReceiveMessage:(LCRTMWebSocketMessage *)message
{
    if (message.type == LCRTMWebSocketMessageTypeData) {
        NSData *data = message.data;
        AssertRunInQueue(self->_internalSerialQueue);
        AVIMGenericCommand *inCommand = ({
            NSError *error = nil;
            AVIMGenericCommand *inCommand = [AVIMGenericCommand parseFromData:data error:&error];
            if (!inCommand) {
                AVLoggerError(AVLoggerDomainIM, @"did receive message with error: %@", error);
                return;
            }
            inCommand;
        });
        AVLoggerInfo(AVLoggerDomainIM, LCIM_IN_COMMAND_LOG_FORMAT, [inCommand avim_description]);
        id<AVIMWebSocketWrapperDelegate> delegate = self->_delegate;
        if (inCommand.hasI && inCommand.i > 0) {
            NSNumber *index = @(inCommand.i);
            LCIMProtobufCommandWrapper *commandWrapper = self->_commandWrapperMap[index];
            if (commandWrapper) {
                [self->_commandWrapperMap removeObjectForKey:index];
                [self->_serialIndexArray removeObject:index];
                commandWrapper.inCommand = inCommand;
                [delegate webSocketWrapper:self didReceiveCommandCallback:commandWrapper];
            }
        } else {
            LCIMProtobufCommandWrapper *commandWrapper = [LCIMProtobufCommandWrapper new];
            commandWrapper.inCommand = inCommand;
            [delegate webSocketWrapper:self didReceiveCommand:commandWrapper];
            if (!inCommand.hasPeerId) {
                [self handleGoawayWith:inCommand];
            }
        }
    } else {
        // NOP
    }
}

// MARK: - Ping Sender

- (void)startPingSender
{
    AssertRunInQueue(self->_internalSerialQueue);
    [self tryStopPingSender];
    self->_pingSenderTimerSource = [self newTimerWithInterval:PingInterval leeway:PingLeeway immediate:true event:^{
        AssertRunInQueue(self->_internalSerialQueue);
        self->_didReceivePong = false;
        self->_lastPingSenderEventTimestamp = NSDate.date.timeIntervalSince1970;
        [self sendPing];
    }];
    dispatch_resume(self->_pingSenderTimerSource);
}

- (void)tryStopPingSender
{
    AssertRunInQueue(self->_internalSerialQueue);
    if (self->_pingSenderTimerSource) {
        dispatch_source_cancel(self->_pingSenderTimerSource);
        self->_pingSenderTimerSource = nil;
        self->_lastPingTimestamp = 0;
        self->_lastPingSenderEventTimestamp = 0;
        self->_didReceivePong = false;
    }
}

- (void)sendPing
{
    AssertRunInQueue(self->_internalSerialQueue);
    LCRTMWebSocket *websocket = self->_websocket;
    if (!websocket || !self.isWebSocketOpened) {
        return;
    }
    self->_lastPingTimestamp = NSDate.date.timeIntervalSince1970;
    NSString *address = [NSString stringWithFormat:@"%p", websocket];
    [websocket sendPing:[NSData data] completion:^{
        AVLoggerInfo(AVLoggerDomainIM, @"<address: %@> websocket send ping.", address);
    }];
}

- (void)LCRTMWebSocket:(LCRTMWebSocket *)socket didReceivePong:(NSData *)data
{
    AssertRunInQueue(self->_internalSerialQueue);
    AVLoggerInfo(AVLoggerDomainIM, @"<address: %p> websocket did receive pong.", socket);
    self->_didReceivePong = true;
}

- (void)LCRTMWebSocket:(LCRTMWebSocket *)socket didReceivePing:(NSData *)data
{
    AssertRunInQueue(self->_internalSerialQueue);
    AVLoggerInfo(AVLoggerDomainIM, @"<address: %p> websocket did receive ping.", socket);
    NSString *address = [NSString stringWithFormat:@"%p", socket];
    [socket sendPong:data completion:^{
        AVLoggerInfo(AVLoggerDomainIM, @"<address: %@> websocket send pong.", address);
    }];
}

// MARK: - Timeout Checker

- (void)startTimeoutChecker
{
    AssertRunInQueue(self->_internalSerialQueue);
    [self tryStopTimeoutChecker];
    self->_timeoutCheckerTimerSource = [self newTimerWithInterval:1 leeway:1 immediate:false event:^{
        AssertRunInQueue(self->_internalSerialQueue);
        [self checkTimeout];
    }];
    dispatch_resume(self->_timeoutCheckerTimerSource);
}

- (void)tryStopTimeoutChecker
{
    AssertRunInQueue(self->_internalSerialQueue);
    if (self->_timeoutCheckerTimerSource) {
        dispatch_source_cancel(self->_timeoutCheckerTimerSource);
        self->_timeoutCheckerTimerSource = nil;
    }
}

- (void)checkTimeout
{
    AssertRunInQueue(self->_internalSerialQueue);
    NSTimeInterval currentTimestamp = NSDate.date.timeIntervalSince1970;
    /// check ping
    if (!self->_didReceivePong && (self->_lastPingTimestamp > 0) && (self->_lastPingSenderEventTimestamp > 0)) {
        NSTimeInterval lastPingTimestamp = self->_lastPingTimestamp;
        NSTimeInterval lastPingSenderEventTimestamp = self->_lastPingSenderEventTimestamp;
        BOOL inRange = ({
            BOOL left = (lastPingTimestamp >= lastPingSenderEventTimestamp);
            BOOL right = (lastPingTimestamp <= (lastPingSenderEventTimestamp + (PingInterval / 2)));
            (left && right);
        });
        if (inRange && (currentTimestamp >= (lastPingTimestamp + PingTimeout))) {
            [self sendPing];
        }
    }
    /// check command
    NSMutableArray<NSNumber *> *timeoutIndexes = [NSMutableArray array];
    for (NSNumber *number in self->_serialIndexArray) {
        LCIMProtobufCommandWrapper *commandWrapper = self->_commandWrapperMap[number];
        if (!commandWrapper) {
            [timeoutIndexes addObject:number];
            continue;
        }
        if (currentTimestamp > commandWrapper.deadlineTimestamp) {
            [timeoutIndexes addObject:number];
            id<AVIMWebSocketWrapperDelegate> delegate = self->_delegate;
            if (delegate) {
                commandWrapper.error = ({
                    AVIMErrorCode code = AVIMErrorCodeCommandTimeout;
                    LCError(code, AVIMErrorMessage(code), nil);
                });
                [delegate webSocketWrapper:self didCommandEncounterError:commandWrapper];
            }
        } else {
            break;
        }
    }
    if (timeoutIndexes.count > 0) {
        [self->_commandWrapperMap removeObjectsForKeys:timeoutIndexes];
        [self->_serialIndexArray removeObjectsInArray:timeoutIndexes];
    }
}

// MARK: - Misc

- (void)addOperationToInternalSerialQueue:(void (^)(AVIMWebSocketWrapper *websocketWrapper))block
{
    dispatch_async(self->_internalSerialQueue, ^{
        block(self);
    });
}

- (NSError *)checkIfCannotConnecting
{
    AssertRunInQueue(self->_internalSerialQueue);
    if (self.isApplicationInBackground) {
        return ({
            AVIMErrorCode code = AVIMErrorCodeConnectionLost;
            NSString *reason = @"Due to application did enter background, connection lost.";
            LCError(code, reason, nil);
        });
    }
    if (self.currentNetworkReachabilityStatus == LCNetworkReachabilityStatusNotReachable) {
        return ({
            AVIMErrorCode code = AVIMErrorCodeConnectionLost;
            NSString *reason = @"Due to network unavailable, connection lost.";
            LCError(code, reason, nil);
        });
    }
    return nil;
}

- (void)notifyInReconnecting
{
    AssertRunInQueue(self->_internalSerialQueue);
    if (!self->_openCallback && !self->_websocket) {
        id<AVIMWebSocketWrapperDelegate> delegate = self->_delegate;
        if ([delegate respondsToSelector:@selector(webSocketWrapperInReconnecting:)]) {
            [delegate webSocketWrapperInReconnecting:self];
        }
    }
}

- (void)pauseWithError:(NSError *)error
{
    AssertRunInQueue(self->_internalSerialQueue);
    if (self->_openCallback) {
        self->_openCallback(false, error);
        self->_openCallback = nil;
    } else {
        id<AVIMWebSocketWrapperDelegate> delegate = self->_delegate;
        if ([delegate respondsToSelector:@selector(webSocketWrapperDidPause:)]) {
            [delegate webSocketWrapperDidPause:self];
        }
    }
}

- (void)closeWithError:(NSError *)error
{
    AssertRunInQueue(self->_internalSerialQueue);
    if (self->_openCallback) {
        self->_openCallback(false, error);
        self->_openCallback = nil;
    } else {
        id<AVIMWebSocketWrapperDelegate> delegate = self->_delegate;
        if ([delegate respondsToSelector:@selector(webSocketWrapper:didCloseWithError:)]) {
            [delegate webSocketWrapper:self didCloseWithError:error];
        }
    }
}

- (void)tryConnecting:(BOOL)force
{
    AssertRunInQueue(self->_internalSerialQueue);
    if (!force && !self->_activatingReconnection) {
        return;
    }
    NSError *firstCannotError = [self checkIfCannotConnecting];
    if (firstCannotError) {
        [self pauseWithError:firstCannotError];
        return;
    }
    [self notifyInReconnecting];
    [self getRTMServerWithCallback:^(NSString *server, NSError *rtmError) {
        AssertRunInQueue(self->_internalSerialQueue);
        if (self->_websocket) {
            return;
        }
        NSError *secondCannotError = [self checkIfCannotConnecting];
        if (secondCannotError) {
            [self pauseWithError:secondCannotError];
        } else {
            if (rtmError) {
                if ([rtmError.domain isEqualToString:NSURLErrorDomain]) {
                    [self pauseWithError:rtmError];
                    [self tryConnecting:false];
                } else {
                    [self closeWithError:rtmError];
                }
            } else {
                [self notifyInReconnecting];
                NSArray<NSString *> *protocols = RTMProtocols();
                NSURL *URL = [NSURL URLWithString:server];
                self->_websocket = [[LCRTMWebSocket alloc] initWithURL:URL protocols:protocols];
                self->_websocket.delegateQueue = self->_internalSerialQueue;
                self->_websocket.delegate = self;
                [self->_websocket.request setValue:nil forHTTPHeaderField:@"Origin"];
                [self->_websocket open];
                __weak typeof(self) weakSelf = self;
                self->_openTimeoutBlock = dispatch_block_create(0, ^{
                    self->_openTimeoutBlock = nil;
                    NSError *error = ({
                        AVIMErrorCode code = AVIMErrorCodeConnectionLost;
                        NSString *reason = @"Due to opening timed out, connection lost.";
                        LCError(code, reason, nil);
                    });
                    [weakSelf purgeWithError:error];
                    [weakSelf pauseWithError:error];
                    [weakSelf tryConnecting:false];
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(AVIMWebSocketDefaultTimeoutInterval * NSEC_PER_SEC)), self->_internalSerialQueue, self->_openTimeoutBlock);
                AVLoggerInfo(AVLoggerDomainIM, @"<address: %p> websocket open with URL: %@, protocols: %@.", self->_websocket, URL, protocols);
            }
        }
    }];
}

- (void)getRTMServerWithCallback:(void (^)(NSString *server, NSError *error))callback
{
    AssertRunInQueue(self->_internalSerialQueue);
    NSString *customRTMServer = AVOSCloudIM.defaultOptions.RTMServer;
    if (customRTMServer) {
        callback(customRTMServer, nil);
    } else {
        [LCRouter.sharedInstance getRTMURLWithAppID:[AVOSCloud getApplicationId] callback:^(NSDictionary *dictionary, NSError *error) {
            [self addOperationToInternalSerialQueue:^(AVIMWebSocketWrapper *websocketWrapper) {
                if (error) {
                    callback(nil, error);
                } else {
                    NSString *primaryServer = [NSString _lc_decoding:dictionary key:RouterKeyRTMServer];
                    NSString *secondaryServer = [NSString _lc_decoding:dictionary key:RouterKeyRTMSecondary];
                    NSString *server = ((websocketWrapper->_useSecondaryServer ? secondaryServer : primaryServer) ?: primaryServer);
                    if (server) {
                        callback(server, nil);
                    } else {
                        callback(nil, LCError(9975, @"Malformed RTM router response.", nil));
                    }
                }
            }];
        }];
    }
}

- (void)purgeWithError:(NSError *)error
{
    AssertRunInQueue(self->_internalSerialQueue);
    self.isWebSocketOpened = false;
    // discard websocket
    if (self->_websocket) {
        AVLoggerInfo(AVLoggerDomainIM, @"<address: %p> websocket discard.", self->_websocket);
        self->_websocket.delegate = nil;
        [self->_websocket closeWithCloseCode:LCRTMWebSocketCloseCodeNormalClosure
                                      reason:nil];
        [self->_websocket safeClean];
        self->_websocket = nil;
    }
    if (self->_openTimeoutBlock) {
        dispatch_block_cancel(self->_openTimeoutBlock);
        self->_openTimeoutBlock = nil;
    }
    // reset ping sender
    [self tryStopPingSender];
    // stop timeout checker
    [self tryStopTimeoutChecker];
    // purge command
    id<AVIMWebSocketWrapperDelegate> delegate = self->_delegate;
    for (NSNumber *number in self->_serialIndexArray) {
        LCIMProtobufCommandWrapper *commandWrapper = self->_commandWrapperMap[number];
        if (commandWrapper && delegate) {
            commandWrapper.error = error;
            [delegate webSocketWrapper:self didCommandEncounterError:commandWrapper];
        }
    }
    [self->_serialIndexArray removeAllObjects];
    [self->_commandWrapperMap removeAllObjects];
}

- (dispatch_source_t)newTimerWithInterval:(uint64_t)interval leeway:(uint64_t)leeway immediate:(BOOL)immediate event:(dispatch_block_t)event
{
    AssertRunInQueue(self->_internalSerialQueue);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_internalSerialQueue);
    dispatch_time_t start = dispatch_time(DISPATCH_TIME_NOW, (immediate ? 0 : interval) * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, start, interval * NSEC_PER_SEC, leeway * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, event);
    return timer;
}

- (uint16_t)serialIndex
{
    AssertRunInQueue(self->_internalSerialQueue);
    self->_serialIndex = (self->_serialIndex == 0) ? 1 : self->_serialIndex;
    uint16_t result = self->_serialIndex;
    self->_serialIndex = (self->_serialIndex + 1) % (UINT16_MAX + 1);
    return result;
}

- (void)handleGoawayWith:(AVIMGenericCommand *)command
{
    AssertRunInQueue(self->_internalSerialQueue);
    if (command.cmd != AVIMCommandType_Goaway) {
        return;
    }
    NSError *error;
    [[LCRouter sharedInstance] cleanCacheWithKey:RouterCacheKeyRTM error:&error];
    if (error) {
        AVLoggerError(AVLoggerDomainIM, @"%@", error);
        return;
    }
    error = ({
        AVIMErrorCode code = AVIMErrorCodeConnectionLost;
        LCError(code, @"Connection did close by local peer.", nil);
    });
    [self purgeWithError:error];
    [self pauseWithError:error];
    [self tryConnecting:false];
}

@end
