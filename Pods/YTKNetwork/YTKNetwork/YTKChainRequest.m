//
//  YTKChainRequest.m
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

#import "YTKChainRequest.h"
#import "YTKChainRequestAgent.h"
#import "YTKNetworkPrivate.h"
#import "YTKBaseRequest.h"

@interface YTKChainRequest()<YTKRequestDelegate>

@property (strong, nonatomic) NSMutableArray<YTKBaseRequest *> *requestArray;
@property (strong, nonatomic) NSMutableArray<YTKChainCallback> *requestCallbackArray;
@property (assign, nonatomic) NSUInteger nextRequestIndex;
@property (strong, nonatomic) YTKChainCallback emptyCallback;

@end

@implementation YTKChainRequest

- (instancetype)init {
    self = [super init];
    if (self) {
        //下一个请求的index
        _nextRequestIndex = 0;
        //保存链式请求的数组
        _requestArray = [NSMutableArray array];
        //保存回调的数组
        _requestCallbackArray = [NSMutableArray array];
        //空回调，用来填充用户没有定义的回调block
        _emptyCallback = ^(YTKChainRequest *chainRequest, YTKBaseRequest *baseRequest) {
            // do nothing
        };
    }
    return self;
}

- (void)start {
    //如果第1个请求已经结束，就不再重复start了
    if (_nextRequestIndex > 0) {
        YTKLog(@"Error! Chain request has already started.");
        return;
    }
    //如果请求队列数组里面还有request，则取出并start
    if ([_requestArray count] > 0) {
        [self toggleAccessoriesWillStartCallBack];
        [self startNextRequest];
        [[YTKChainRequestAgent sharedAgent] addChainRequest:self];
    } else {
        YTKLog(@"Error! Chain request array is empty.");
    }
}

- (void)stop {
    [self toggleAccessoriesWillStopCallBack];
    [self clearRequest];
    [[YTKChainRequestAgent sharedAgent] removeChainRequest:self];
    [self toggleAccessoriesDidStopCallBack];
}
//在当前chain添加request和callback
- (void)addRequest:(YTKBaseRequest *)request callback:(YTKChainCallback)callback {
    //保存当前请求
    [_requestArray addObject:request];
    if (callback != nil) {
        [_requestCallbackArray addObject:callback];
    } else {
        //之所以特意弄一个空的callback，是为了避免在用户没有给当前request的callback传值的情况下，造成request数组和callback数组的不对称
        [_requestCallbackArray addObject:_emptyCallback];
    }
}

- (NSArray<YTKBaseRequest *> *)requestArray {
    return _requestArray;
}


//这里startNextRequest方法比较重要：在判断请求队列数组里面还有request的话，就会调用这个方法：
- (BOOL)startNextRequest {
    if (_nextRequestIndex < [_requestArray count]) {
        YTKBaseRequest *request = _requestArray[_nextRequestIndex];
        _nextRequestIndex++;
        request.delegate = self;
        [request clearCompletionBlock];
        [request start];
        return YES;
    } else {
        return NO;
    }
}

#pragma mark - Network Request Delegate

- (void)requestFinished:(YTKBaseRequest *)request {
    NSUInteger currentRequestIndex = _nextRequestIndex - 1;
    YTKChainCallback callback = _requestCallbackArray[currentRequestIndex];
    callback(self, request);
    if (![self startNextRequest]) {
        [self toggleAccessoriesWillStopCallBack];
        if ([_delegate respondsToSelector:@selector(chainRequestFinished:)]) {
            [_delegate chainRequestFinished:self];
            [[YTKChainRequestAgent sharedAgent] removeChainRequest:self];
        }
        [self toggleAccessoriesDidStopCallBack];
    }
}

- (void)requestFailed:(YTKBaseRequest *)request {
    [self toggleAccessoriesWillStopCallBack];
    if ([_delegate respondsToSelector:@selector(chainRequestFailed:failedBaseRequest:)]) {
        [_delegate chainRequestFailed:self failedBaseRequest:request];
        [[YTKChainRequestAgent sharedAgent] removeChainRequest:self];
    }
    [self toggleAccessoriesDidStopCallBack];
}

- (void)clearRequest {
    NSUInteger currentRequestIndex = _nextRequestIndex - 1;
    if (currentRequestIndex < [_requestArray count]) {
        YTKBaseRequest *request = _requestArray[currentRequestIndex];
        [request stop];
    }
    [_requestArray removeAllObjects];
    [_requestCallbackArray removeAllObjects];
}

#pragma mark - Request Accessoies

- (void)addAccessory:(id<YTKRequestAccessory>)accessory {
    if (!self.requestAccessories) {
        self.requestAccessories = [NSMutableArray array];
    }
    [self.requestAccessories addObject:accessory];
}

@end
