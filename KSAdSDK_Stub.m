/**
 * KSAdSDK Stub Framework - 空壳版本
 *
 * 目的：替换原始KSAdSDK.framework，消除KSUWeapon/ADDFPSecurityTool等检测逻辑
 * 原理：只导出游戏(UnityFramework)实际需要的9个符号，其余类全部省略
 *       检测函数不存在→无法执行→反作弊检测自然失效
 *
 * UnityFramework从KSAdSDK导入的符号：
 *   _KSAdADNNameBaidu          (NSString常量)
 *   _KSAdADNNameChuanshanjia   (NSString常量)
 *   _KSAdADNNameOther          (NSString常量)
 *   _OBJC_CLASS_$_KSAdBiddingAdV2Model
 *   _OBJC_CLASS_$_KSAdExposureReportParam
 *   _OBJC_CLASS_$_KSAdExtraDataModel
 *   _OBJC_CLASS_$_KSAdNativeAdExtraDataModel
 *   _OBJC_CLASS_$_KSAdSDKConfiguration
 *   _OBJC_CLASS_$_KSAdSDKManager
 */

#import <Foundation/Foundation.h>

#pragma mark - String Constants

NSString * const KSAdADNNameBaidu = @"baidu";
NSString * const KSAdADNNameChuanshanjia = @"chuanshanjia";
NSString * const KSAdADNNameOther = @"other";

#pragma mark - KSAdBiddingAdV2Model

@interface KSAdBiddingAdV2Model : NSObject
@property (nonatomic, copy) NSString *adId;
@property (nonatomic, assign) double bidPrice;
@property (nonatomic, copy) NSString *currencyType;
@end

@implementation KSAdBiddingAdV2Model
@end

#pragma mark - KSAdExposureReportParam

@interface KSAdExposureReportParam : NSObject
@property (nonatomic, copy) NSString *adId;
@property (nonatomic, copy) NSString *unitId;
@end

@implementation KSAdExposureReportParam
@end

#pragma mark - KSAdExtraDataModel

@interface KSAdExtraDataModel : NSObject
@property (nonatomic, copy) NSString *adId;
@property (nonatomic, copy) NSDictionary *extraData;
@end

@implementation KSAdExtraDataModel
@end

#pragma mark - KSAdNativeAdExtraDataModel

@interface KSAdNativeAdExtraDataModel : NSObject
@property (nonatomic, copy) NSString *adId;
@property (nonatomic, copy) NSDictionary *extraData;
@end

@implementation KSAdNativeAdExtraDataModel
@end

#pragma mark - KSAdSDKConfiguration

@interface KSAdSDKConfiguration : NSObject
@property (nonatomic, copy) NSString *appId;
@property (nonatomic, assign) BOOL showDebugLog;
@property (nonatomic, assign) BOOL enableDKSKU;
@end

@implementation KSAdSDKConfiguration
@end

#pragma mark - KSAdSDKManager

@interface KSAdSDKManager : NSObject
@end

@implementation KSAdSDKManager

+ (instancetype)sharedInstance {
    static KSAdSDKManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KSAdSDKManager alloc] init];
    });
    return instance;
}

+ (instancetype)sharedManager {
    return [self sharedInstance];
}

- (void)startWithConfig:(KSAdSDKConfiguration *)config {
    // 空实现 - 不初始化任何广告SDK
    NSLog(@"[KSAdSDK-Stub] startWithConfig called, appId=%@", config.appId);
}

@end
