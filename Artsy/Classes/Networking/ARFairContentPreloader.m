#import "ARFairContentPreloader.h"
#import <netinet/in.h>
#import <arpa/inet.h>

@interface ARFairContentPreloader () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (nonatomic, strong) NSNetServiceBrowser *serviceBrowser;
@property (nonatomic, strong) NSNetService *service;
@property (nonatomic, strong) NSURL *serviceURL;
@property (nonatomic, strong) NSDictionary *manifest;
@property (nonatomic, assign) BOOL isResolvingService;
@end

@implementation ARFairContentPreloader

+ (instancetype)contentPreloader;
{
  return [[self alloc] initWithServiceName:@"Artsy-FairEnough-Server"];
}

- (instancetype)initWithServiceName:(NSString *)serviceName;
{
   if ((self = [super init])) {
     _serviceName = [serviceName copy];
   }
   return self;
}

- (void)discoverFairService;
{
  self.isResolvingService = YES;
  self.serviceBrowser = [NSNetServiceBrowser new];
  self.serviceBrowser.delegate = self;
  [self.serviceBrowser searchForServicesOfType:@"_http._tcp" inDomain:@""];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreServicesComing;
{
  ARActionLog(@"[FairEnough] Found Bonjour service: %@", service);
  if ([service.name isEqualToString:self.serviceName]) {
    self.service = service;
    if (service.addresses.count > 0) {
      [self resolveAddress];
    } else {
      self.service.delegate = self;
      [self.service resolveWithTimeout:10];
    }
    [self.serviceBrowser stop];
    return;
  }
  if (!moreServicesComing) {
    [self.serviceBrowser stop];
    // TODO Tell delegate to release this object.
    self.isResolvingService = NO;
  }
}

- (void)netServiceDidResolveAddress:(NSNetService *)service;
{
  if (service.addresses.count > 0) {
    [service stop];
    [self resolveAddress];
  }
}

- (BOOL)hasResolvedService;
{
  return self.service.addresses.count > 0;
}

- (void)netServiceDidStop:(NSNetService *)service;
{
  self.isResolvingService = NO;
  if (!self.hasResolvedService) {
    ARActionLog(@"[FairEnough] Failed to resolve a Artsy-FairEnough-Server Bonjour service.");
  }
}

- (void)resolveAddress;
{
  for (NSData *addressData in self.service.addresses) {
    const struct sockaddr *address = (const struct sockaddr *)addressData.bytes;
    // IPv4
    if (address->sa_family == AF_INET) {
      self.serviceURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://%s:%ld", inet_ntoa(((struct sockaddr_in *)address)->sin_addr), (long)self.service.port]];
    } else if (address->sa_family == AF_INET6) {
      // TODO?
      // NSLog(@"Found IPv6 address");
    }
  }
}

- (void)fetchManifest:(void(^)(NSError *))completionBlock;
{
  @weakify(self);
  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:self.manifestURL
                                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    @strongify(self);
    if (!self) return;

    NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
    if (statusCode < 200 || statusCode >= 300) {
      ARErrorLog(@"Unexpected response from FairEnough HTTP server: %@", response);
      completionBlock([NSError errorWithDomain:@"ARFairContentPreloaderErrorDomain"
                                          code:statusCode
                                      userInfo:@{ NSLocalizedDescriptionKey:@"Unexpected HTTP status code." }]);
    } else if (data) {
      NSError *jsonError = nil;
      self.manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
      if (self.manifest) {
        completionBlock(nil);
      } else {
        completionBlock(jsonError);
      }
    } else {
      completionBlock(error);
    }
  }];
  [task resume];
}

- (void)fetchPackage:(void(^)(NSError *))completionBlock;
{
  NSURL *partiallyDownloadedPackageURL = self.partiallyDownloadedPackageURL;
  NSURL *temporaryLocalPackageURL = self.temporaryLocalPackageURL;

  void (^taskCompletionBlock)(NSURL *, NSURLResponse *, NSError *);
  taskCompletionBlock = ^(NSURL *location, NSURLResponse *response, NSError *error) {
    if (error) {
      NSData *resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
      if (resumeData) {
        [resumeData writeToURL:partiallyDownloadedPackageURL atomically:YES];
      }
      completionBlock(error);
    } else {
      [[NSFileManager defaultManager] moveItemAtURL:location toURL:temporaryLocalPackageURL error:&error];
      completionBlock(nil);
    }
  };

  NSURLSessionDownloadTask *task = nil;
  NSData *resumeData = [NSData dataWithContentsOfURL:partiallyDownloadedPackageURL];
  if (resumeData) {
    task = [[NSURLSession sharedSession] downloadTaskWithResumeData:resumeData
                                                  completionHandler:taskCompletionBlock];
  } else {
    task = [[NSURLSession sharedSession] downloadTaskWithURL:self.packageURL
                                           completionHandler:taskCompletionBlock];
  }
  // NSAssert(task != nil, @"Expected an instance of NSURLSessionDownloadTask");
  [task resume];
}

- (NSURL *)manifestURL;
{
  return [self.serviceURL URLByAppendingPathComponent:@"/fair/manifest.json"];
}

- (NSURL *)packageURL;
{
  return [self.serviceURL URLByAppendingPathComponent:@"/fair/package.zip"];
}

- (NSURL *)temporaryLocalPackageURL;
{
  NSString *filename = [self.fairName stringByAppendingPathExtension:@"zip"];
  return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
}

- (NSURL *)partiallyDownloadedPackageURL;
{
  return [self.temporaryLocalPackageURL URLByAppendingPathExtension:@"partial"];
}

- (NSString *)fairName;
{
  return self.manifest[@"fair"];
}

- (NSUInteger)packageSize;
{
  return [self.manifest[@"package-size"] unsignedIntegerValue];
}

- (NSUInteger)unpackedSize;
{
  return [self.manifest[@"unpacked-size"] unsignedIntegerValue];
}

- (NSUInteger)requiredDiskSpace;
{
  return self.packageSize + self.unpackedSize;
}

- (BOOL)hasEnoughFreeDiskSpace;
{
  NSError *error = nil;
  NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory()
                                                                                     error:&error];
  return [attributes[NSFileSystemFreeSize] unsignedIntegerValue] >= self.requiredDiskSpace;
}

@end