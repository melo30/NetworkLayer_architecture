//
//  YTKNetworkAgent.m
//
//  Copyright (c) 2012-2016 YTKNetwork https://github.com/yuantiku
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "YTKNetworkAgent.h"
#import "YTKNetworkConfig.h"
#import "YTKNetworkPrivate.h"
#import <pthread/pthread.h>

#if __has_include(<AFNetworking/AFNetworking.h>)
#import <AFNetworking/AFNetworking.h>
#else
#import "AFNetworking.h"
#endif

#define Lock() pthread_mutex_lock(&_lock)
#define Unlock() pthread_mutex_unlock(&_lock)

#define kYTKNetworkIncompleteDownloadFolderName @"Incomplete"

@implementation YTKNetworkAgent {
    AFHTTPSessionManager *_manager;
    YTKNetworkConfig *_config;
    AFJSONResponseSerializer *_jsonResponseSerializer;
    AFXMLParserResponseSerializer *_xmlParserResponseSerialzier;
    NSMutableDictionary<NSNumber *, YTKBaseRequest *> *_requestsRecord;

    dispatch_queue_t _processingQueue;
    pthread_mutex_t _lock;
    NSIndexSet *_allStatusCodes;
}

+ (YTKNetworkAgent *)sharedAgent {
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _config = [YTKNetworkConfig sharedConfig];
        _manager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:_config.sessionConfiguration];
        _requestsRecord = [NSMutableDictionary dictionary];
        _processingQueue = dispatch_queue_create("com.yuantiku.networkagent.processing", DISPATCH_QUEUE_CONCURRENT);
        _allStatusCodes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(100, 500)];
        pthread_mutex_init(&_lock, NULL);

        _manager.securityPolicy = _config.securityPolicy;
        _manager.responseSerializer = [AFHTTPResponseSerializer serializer];
        // Take over the status code validation
        _manager.responseSerializer.acceptableStatusCodes = _allStatusCodes;
        _manager.completionQueue = _processingQueue;
    }
    return self;
}

- (AFJSONResponseSerializer *)jsonResponseSerializer {
    if (!_jsonResponseSerializer) {
        _jsonResponseSerializer = [AFJSONResponseSerializer serializer];
        _jsonResponseSerializer.acceptableStatusCodes = _allStatusCodes;

    }
    return _jsonResponseSerializer;
}

- (AFXMLParserResponseSerializer *)xmlParserResponseSerialzier {
    if (!_xmlParserResponseSerialzier) {
        _xmlParserResponseSerialzier = [AFXMLParserResponseSerializer serializer];
        _xmlParserResponseSerialzier.acceptableStatusCodes = _allStatusCodes;
    }
    return _xmlParserResponseSerialzier;
}

#pragma mark -

- (NSString *)buildRequestUrl:(YTKBaseRequest *)request {
    NSParameterAssert(request != nil);

    NSString *detailUrl = [request requestUrl];
    NSURL *temp = [NSURL URLWithString:detailUrl];
    // If detailUrl is valid URL
    if (temp && temp.host && temp.scheme) {
        return detailUrl;
    }
    // Filter URL if needed
    NSArray *filters = [_config urlFilters];
    for (id<YTKUrlFilterProtocol> f in filters) {
        detailUrl = [f filterUrl:detailUrl withRequest:request];
    }

    NSString *baseUrl;
    if ([request useCDN]) {
        if ([request cdnUrl].length > 0) {
            baseUrl = [request cdnUrl];
        } else {
            baseUrl = [_config cdnUrl];
        }
    } else {
        if ([request baseUrl].length > 0) {
            baseUrl = [request baseUrl];
        } else {
            baseUrl = [_config baseUrl];
        }
    }
    // URL slash compability
    NSURL *url = [NSURL URLWithString:baseUrl];

    if (baseUrl.length > 0 && ![baseUrl hasSuffix:@"/"]) {
        url = [url URLByAppendingPathComponent:@""];
    }

    return [NSURL URLWithString:detailUrl relativeToURL:url].absoluteString;
}

- (AFHTTPRequestSerializer *)requestSerializerForRequest:(YTKBaseRequest *)request {
    AFHTTPRequestSerializer *requestSerializer = nil;
    
    //HTTP or JSON
    if (request.requestSerializerType == YTKRequestSerializerTypeHTTP) {
        requestSerializer = [AFHTTPRequestSerializer serializer];
    } else if (request.requestSerializerType == YTKRequestSerializerTypeJSON) {
        requestSerializer = [AFJSONRequestSerializer serializer];
    }

    //超时时间
    requestSerializer.timeoutInterval = [request requestTimeoutInterval];
    //是否允许数据服务
    requestSerializer.allowsCellularAccess = [request allowsCellularAccess];

    // If api needs server username and password
    //如果当前请求需要验证
    NSArray<NSString *> *authorizationHeaderFieldArray = [request requestAuthorizationHeaderFieldArray];
    if (authorizationHeaderFieldArray != nil) {
        [requestSerializer setAuthorizationHeaderFieldWithUsername:authorizationHeaderFieldArray.firstObject
                                                          password:authorizationHeaderFieldArray.lastObject];
    }

    // If api needs to add custom value to HTTPHeaderField
    //如果当前请求需要自定义 HTTPHeaderField
    NSDictionary<NSString *, NSString *> *headerFieldValueDictionary = [request requestHeaderFieldValueDictionary];
    if (headerFieldValueDictionary != nil) {
        for (NSString *httpHeaderField in headerFieldValueDictionary.allKeys) {
            NSString *value = headerFieldValueDictionary[httpHeaderField];
            [requestSerializer setValue:value forHTTPHeaderField:httpHeaderField];
        }
    }
    return requestSerializer;
}

- (NSURLSessionTask *)sessionTaskForRequest:(YTKBaseRequest *)request error:(NSError * _Nullable __autoreleasing *)error {
    //1. 获得请求类型（GET，POST等）
    YTKRequestMethod method = [request requestMethod];
     //2. 获得请求url
    NSString *url = [self buildRequestUrl:request];
    //3. 获得请求参数
    id param = request.requestArgument;
    AFConstructingBlock constructingBlock = [request constructingBodyBlock];
    //4. 获得request serializer
    AFHTTPRequestSerializer *requestSerializer = [self requestSerializerForRequest:request];

    //5. 根据不同的请求类型来返回对应的task
    switch (method) {
        case YTKRequestMethodGET:
            if (request.resumableDownloadPath) {
                //下载任务
                return [self downloadTaskWithDownloadPath:request.resumableDownloadPath requestSerializer:requestSerializer URLString:url parameters:param progress:request.resumableDownloadProgressBlock error:error];
            } else {
                //普通get请求
                return [self dataTaskWithHTTPMethod:@"GET" requestSerializer:requestSerializer URLString:url parameters:param error:error];
            }
        case YTKRequestMethodPOST:
            //post请求
            return [self dataTaskWithHTTPMethod:@"POST" requestSerializer:requestSerializer URLString:url parameters:param constructingBodyWithBlock:constructingBlock error:error];
        case YTKRequestMethodHEAD:
            //HEAD请求
            return [self dataTaskWithHTTPMethod:@"HEAD" requestSerializer:requestSerializer URLString:url parameters:param error:error];
        case YTKRequestMethodPUT:
            //PUT请求
            return [self dataTaskWithHTTPMethod:@"PUT" requestSerializer:requestSerializer URLString:url parameters:param error:error];
        case YTKRequestMethodDELETE:
            //DELET请求
            return [self dataTaskWithHTTPMethod:@"DELETE" requestSerializer:requestSerializer URLString:url parameters:param error:error];
        case YTKRequestMethodPATCH:
            //PATCH请求
            return [self dataTaskWithHTTPMethod:@"PATCH" requestSerializer:requestSerializer URLString:url parameters:param error:error];
    }
}

/** 当前的请求添加进来并发送请求 */
- (void)addRequest:(YTKBaseRequest *)request {
    /**
     第一部分是获取当前请求对应的task并赋给request的requestTask属性（以后提到的request，都为用户自定义的当前请求类的实例）。
     第二部分是把request放入专门用来保存请求的字典中，key为taskIdentifier。
     第三部分是启动task。
     */
    
    
    //获取task
    NSParameterAssert(request != nil);

    NSError * __autoreleasing requestSerializationError = nil;

    // 获取用户自定义的requestUrl
    NSURLRequest *customUrlRequest= [request buildCustomUrlRequest];
    if (customUrlRequest) {
        __block NSURLSessionDataTask *dataTask = nil;
        //如果存在用户自定义request，则直接走AFNetworking的dataTaskWithRequest:方法
        dataTask = [_manager dataTaskWithRequest:customUrlRequest completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
            //响应的统一处理
            [self handleRequestResult:dataTask responseObject:responseObject error:error];
        }];
        request.requestTask = dataTask;
    } else {
        //如果用户没有自定义url，则直接走这里
        request.requestTask = [self sessionTaskForRequest:request error:&requestSerializationError];
    }

    //序列化失败，则认定为请求失败
    if (requestSerializationError) {
        [self requestDidFailWithRequest:request error:requestSerializationError];
        return;
    }

    NSAssert(request.requestTask != nil, @"requestTask should not be nil");

    // Set request task priority
    // !!Available on iOS 8 +
    if ([request.requestTask respondsToSelector:@selector(priority)]) {
        switch (request.requestPriority) {
            case YTKRequestPriorityHigh:
                request.requestTask.priority = NSURLSessionTaskPriorityHigh;
                break;
            case YTKRequestPriorityLow:
                request.requestTask.priority = NSURLSessionTaskPriorityLow;
                break;
            case YTKRequestPriorityDefault:
                /*!!fall through*/
            default:
                request.requestTask.priority = NSURLSessionTaskPriorityDefault;
                break;
        }
    }

    // Retain request
    YTKLog(@"Add request: %@", NSStringFromClass([request class]));
    
    ////2. 将request放入保存请求的字典中，taskIdentifier为key，request为值
    [self addRequestToRecord:request];
    //3. 开始task
    [request.requestTask resume];
}

- (void)cancelRequest:(YTKBaseRequest *)request {
    NSParameterAssert(request != nil);

    if (request.resumableDownloadPath) {
        NSURLSessionDownloadTask *requestTask = (NSURLSessionDownloadTask *)request.requestTask;
        [requestTask cancelByProducingResumeData:^(NSData *resumeData) {
            NSURL *localUrl = [self incompleteDownloadTempPathForDownloadPath:request.resumableDownloadPath];
            [resumeData writeToURL:localUrl atomically:YES];
        }];
    } else {
        [request.requestTask cancel];
    }

    [self removeRequestFromRecord:request];
    [request clearCompletionBlock];
}

- (void)cancelAllRequests {
    Lock();
    NSArray *allKeys = [_requestsRecord allKeys];
    Unlock();
    if (allKeys && allKeys.count > 0) {
        NSArray *copiedKeys = [allKeys copy];
        for (NSNumber *key in copiedKeys) {
            Lock();
            YTKBaseRequest *request = _requestsRecord[key];
            Unlock();
            // We are using non-recursive lock.
            // Do not lock `stop`, otherwise deadlock may occur.
            [request stop];
        }
    }
}

- (BOOL)validateResult:(YTKBaseRequest *)request error:(NSError * _Nullable __autoreleasing *)error {
    BOOL result = [request statusCodeValidator];
    if (!result) {
        if (error) {
            *error = [NSError errorWithDomain:YTKRequestValidationErrorDomain code:YTKRequestValidationErrorInvalidStatusCode userInfo:@{NSLocalizedDescriptionKey:@"Invalid status code"}];
        }
        return result;
    }
    id json = [request responseJSONObject];
    id validator = [request jsonValidator];
    if (json && validator) {
        result = [YTKNetworkUtils validateJSON:json withValidator:validator];
        if (!result) {
            if (error) {
                *error = [NSError errorWithDomain:YTKRequestValidationErrorDomain code:YTKRequestValidationErrorInvalidJSONFormat userInfo:@{NSLocalizedDescriptionKey:@"Invalid JSON format"}];
            }
            return result;
        }
    }
    return YES;
}
//统一处理请求结果，包括成功和失败的情况
- (void)handleRequestResult:(NSURLSessionTask *)task responseObject:(id)responseObject error:(NSError *)error {
    //1. 获取task对应的request
    Lock();
    YTKBaseRequest *request = _requestsRecord[@(task.taskIdentifier)];
    Unlock();

    // When the request is cancelled and removed from records, the underlying
    // AFNetworking failure callback will still kicks in, resulting in a nil `request`.
    //
    // Here we choose to completely ignore cancelled tasks. Neither success or failure
    // callback will be called.
    
    //如果不存在对应的request，则立即返回
    
    if (!request) {
        return;
    }

    YTKLog(@"Finished Request: %@", NSStringFromClass([request class]));

    NSError * __autoreleasing serializationError = nil;
    NSError * __autoreleasing validationError = nil;

    NSError *requestError = nil;
    BOOL succeed = NO;

    request.responseObject = responseObject;
    if ([request.responseObject isKindOfClass:[NSData class]]) {
        request.responseData = responseObject;
        request.responseString = [[NSString alloc] initWithData:responseObject encoding:[YTKNetworkUtils stringEncodingWithRequest:request]];

        switch (request.responseSerializerType) {
            case YTKResponseSerializerTypeHTTP:
                // Default serializer. Do nothing.
                break;
            case YTKResponseSerializerTypeJSON:
                request.responseObject = [self.jsonResponseSerializer responseObjectForResponse:task.response data:request.responseData error:&serializationError];
                request.responseJSONObject = request.responseObject;
                break;
            case YTKResponseSerializerTypeXMLParser:
                request.responseObject = [self.xmlParserResponseSerialzier responseObjectForResponse:task.response data:request.responseData error:&serializationError];
                break;
        }
    }
    if (error) {
        succeed = NO;
        requestError = error;
    } else if (serializationError) {
        succeed = NO;
        requestError = serializationError;
    } else {
        succeed = [self validateResult:request error:&validationError];
        requestError = validationError;
    }
 //5. 根据succeed的布尔值来调用相应的处理
    if (succeed) {
        //请求成功的处理
        [self requestDidSucceedWithRequest:request];
    } else {
        //请求失败的处理
        [self requestDidFailWithRequest:request error:requestError];
    }

     //6. 回调完成的处理
    dispatch_async(dispatch_get_main_queue(), ^{
        //6.1 在字典里移除当前request
        [self removeRequestFromRecord:request];
        //6.2 清除所有block
        [request clearCompletionBlock];
    });
}

- (void)requestDidSucceedWithRequest:(YTKBaseRequest *)request {
    @autoreleasepool {
         //写入缓存
        [request requestCompletePreprocessor];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        //告诉Accessories请求就要停止了
        [request toggleAccessoriesWillStopCallBack];
        //在真正的回调之前做的处理,用户自定义
        [request requestCompleteFilter];

        if (request.delegate != nil) {
             //如果有代理，则调用成功的代理
            [request.delegate requestFinished:request];
        }
        //如果传入了成功回调的代码，则调用
        if (request.successCompletionBlock) {
            request.successCompletionBlock(request);
        }
        [request toggleAccessoriesDidStopCallBack];
    });
}

- (void)requestDidFailWithRequest:(YTKBaseRequest *)request error:(NSError *)error {
    request.error = error;
    YTKLog(@"Request %@ failed, status code = %ld, error = %@",
           NSStringFromClass([request class]), (long)request.responseStatusCode, error.localizedDescription);

    // Save incomplete download data.
    NSData *incompleteDownloadData = error.userInfo[NSURLSessionDownloadTaskResumeData];
    if (incompleteDownloadData) {
        [incompleteDownloadData writeToURL:[self incompleteDownloadTempPathForDownloadPath:request.resumableDownloadPath] atomically:YES];
    }

    // Load response from file and clean up if download task failed.
    if ([request.responseObject isKindOfClass:[NSURL class]]) {
        NSURL *url = request.responseObject;
        if (url.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            request.responseData = [NSData dataWithContentsOfURL:url];
            request.responseString = [[NSString alloc] initWithData:request.responseData encoding:[YTKNetworkUtils stringEncodingWithRequest:request]];

            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        }
        request.responseObject = nil;
    }

    @autoreleasepool {
        [request requestFailedPreprocessor];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [request toggleAccessoriesWillStopCallBack];
        [request requestFailedFilter];

        if (request.delegate != nil) {
            [request.delegate requestFailed:request];
        }
        if (request.failureCompletionBlock) {
            request.failureCompletionBlock(request);
        }
        [request toggleAccessoriesDidStopCallBack];
    });
}

- (void)addRequestToRecord:(YTKBaseRequest *)request {
    Lock();
    _requestsRecord[@(request.requestTask.taskIdentifier)] = request;
    Unlock();
}

- (void)removeRequestFromRecord:(YTKBaseRequest *)request {
    Lock();
    [_requestsRecord removeObjectForKey:@(request.requestTask.taskIdentifier)];
    YTKLog(@"Request queue size = %zd", [_requestsRecord count]);
    Unlock();
}

#pragma mark - 私有方法

- (NSURLSessionDataTask *)dataTaskWithHTTPMethod:(NSString *)method
                               requestSerializer:(AFHTTPRequestSerializer *)requestSerializer
                                       URLString:(NSString *)URLString
                                      parameters:(id)parameters
                                           error:(NSError * _Nullable __autoreleasing *)error {
    return [self dataTaskWithHTTPMethod:method requestSerializer:requestSerializer URLString:URLString parameters:parameters constructingBodyWithBlock:nil error:error];
}
//最终返回NSURLSessionDataTask实例
- (NSURLSessionDataTask *)dataTaskWithHTTPMethod:(NSString *)method
                               requestSerializer:(AFHTTPRequestSerializer *)requestSerializer
                                       URLString:(NSString *)URLString
                                      parameters:(id)parameters
                       constructingBodyWithBlock:(nullable void (^)(id <AFMultipartFormData> formData))block
                                           error:(NSError * _Nullable __autoreleasing *)error {
    NSMutableURLRequest *request = nil;
    //根据有无构造请求体的block的情况来获取request
    if (block) {
        request = [requestSerializer multipartFormRequestWithMethod:method URLString:URLString parameters:parameters constructingBodyWithBlock:block error:error];
    } else {
        request = [requestSerializer requestWithMethod:method URLString:URLString parameters:parameters error:error];
    }

     //获得request以后来获取dataTask
    __block NSURLSessionDataTask *dataTask = nil;
    dataTask = [_manager dataTaskWithRequest:request
                           completionHandler:^(NSURLResponse * __unused response, id responseObject, NSError *_error) {
                               //响应的统一处理
                               [self handleRequestResult:dataTask responseObject:responseObject error:_error];
                           }];

    return dataTask;
}

- (NSURLSessionDownloadTask *)downloadTaskWithDownloadPath:(NSString *)downloadPath
                                         requestSerializer:(AFHTTPRequestSerializer *)requestSerializer
                                                 URLString:(NSString *)URLString
                                                parameters:(id)parameters
                                                  progress:(nullable void (^)(NSProgress *downloadProgress))downloadProgressBlock
                                                     error:(NSError * _Nullable __autoreleasing *)error {
    // add parameters to URL;
    NSMutableURLRequest *urlRequest = [requestSerializer requestWithMethod:@"GET" URLString:URLString parameters:parameters error:error];

    NSString *downloadTargetPath;
    BOOL isDirectory;
    if(![[NSFileManager defaultManager] fileExistsAtPath:downloadPath isDirectory:&isDirectory]) {
        isDirectory = NO;
    }
    // If targetPath is a directory, use the file name we got from the urlRequest.
    // Make sure downloadTargetPath is always a file, not directory.
    if (isDirectory) {
        NSString *fileName = [urlRequest.URL lastPathComponent];
        downloadTargetPath = [NSString pathWithComponents:@[downloadPath, fileName]];
    } else {
        downloadTargetPath = downloadPath;
    }

    // AFN use `moveItemAtURL` to move downloaded file to target path,
    // this method aborts the move attempt if a file already exist at the path.
    // So we remove the exist file before we start the download task.
    // https://github.com/AFNetworking/AFNetworking/issues/3775
    if ([[NSFileManager defaultManager] fileExistsAtPath:downloadTargetPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:downloadTargetPath error:nil];
    }

    BOOL resumeDataFileExists = [[NSFileManager defaultManager] fileExistsAtPath:[self incompleteDownloadTempPathForDownloadPath:downloadPath].path];
    NSData *data = [NSData dataWithContentsOfURL:[self incompleteDownloadTempPathForDownloadPath:downloadPath]];
    BOOL resumeDataIsValid = [YTKNetworkUtils validateResumeData:data];

    BOOL canBeResumed = resumeDataFileExists && resumeDataIsValid;
    BOOL resumeSucceeded = NO;
    __block NSURLSessionDownloadTask *downloadTask = nil;
    // Try to resume with resumeData.
    // Even though we try to validate the resumeData, this may still fail and raise excecption.
    if (canBeResumed) {
        @try {
            downloadTask = [_manager downloadTaskWithResumeData:data progress:downloadProgressBlock destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
                return [NSURL fileURLWithPath:downloadTargetPath isDirectory:NO];
            } completionHandler:
                            ^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
                                [self handleRequestResult:downloadTask responseObject:filePath error:error];
                            }];
            resumeSucceeded = YES;
        } @catch (NSException *exception) {
            YTKLog(@"Resume download failed, reason = %@", exception.reason);
            resumeSucceeded = NO;
        }
    }
    if (!resumeSucceeded) {
        downloadTask = [_manager downloadTaskWithRequest:urlRequest progress:downloadProgressBlock destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
            return [NSURL fileURLWithPath:downloadTargetPath isDirectory:NO];
        } completionHandler:
                        ^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
                            [self handleRequestResult:downloadTask responseObject:filePath error:error];
                        }];
    }
    return downloadTask;
}

#pragma mark - Resumable Download

- (NSString *)incompleteDownloadTempCacheFolder {
    NSFileManager *fileManager = [NSFileManager new];
    static NSString *cacheFolder;

    if (!cacheFolder) {
        NSString *cacheDir = NSTemporaryDirectory();
        cacheFolder = [cacheDir stringByAppendingPathComponent:kYTKNetworkIncompleteDownloadFolderName];
    }

    NSError *error = nil;
    if(![fileManager createDirectoryAtPath:cacheFolder withIntermediateDirectories:YES attributes:nil error:&error]) {
        YTKLog(@"Failed to create cache directory at %@", cacheFolder);
        cacheFolder = nil;
    }
    return cacheFolder;
}

- (NSURL *)incompleteDownloadTempPathForDownloadPath:(NSString *)downloadPath {
    NSString *tempPath = nil;
    NSString *md5URLString = [YTKNetworkUtils md5StringFromString:downloadPath];
    tempPath = [[self incompleteDownloadTempCacheFolder] stringByAppendingPathComponent:md5URLString];
    return [NSURL fileURLWithPath:tempPath];
}

#pragma mark - Testing

- (AFHTTPSessionManager *)manager {
    return _manager;
}

- (void)resetURLSessionManager {
    _manager = [AFHTTPSessionManager manager];
}

- (void)resetURLSessionManagerWithConfiguration:(NSURLSessionConfiguration *)configuration {
    _manager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:configuration];
}

@end
