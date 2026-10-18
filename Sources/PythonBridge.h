#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MusicPythonBridge : NSObject
+ (nullable NSString *)call:(NSString *)request resourcePath:(NSString *)path error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
