# NetworkLayer_architecture

YTKNetwork

一直在用YTKNetwork,最近两天把它源码比较详细研究了一遍，收获颇丰。它是猿题库技术团队开源的一个网络请求框架，内部封装了AFNetworking。它把每个请求实例化，管理它的生命周期，也可以管理多个请求和链式请求

1.YTKNetwork框架将每一个请求实例化，YTKBaseRequest是所有请求类的基类，YTKRequest是它的子类。所以如果我们想要发送一个请求，则需要创建并实例化一个继承于YTKRequest的自定义的请求类（CustomRequest）并发送请求。
2.YTKNetworkAgent是一个单例，负责管理所有的请求类（例如CustomRequest）。当CustomRequest发送请求以后，会把自己放在YTKNetworkAgent持有的一个字典里，让其管理自己。
我们说YTKNetwork封装了AFNetworking，实际上是YTKNetworkAgent封装了AFNetworking，由它负责AFNetworking请求的发送和AFNetworking的回调处理。所以如果我们想更换一个第三方网络请求库，就可以在这里更换一下。而YTKRequest更多的是只是负责缓存的处理。

阅读步骤：（代码内附有详细注释）
1.YTKBaseRequst发起一个普通网络请求
2.YTKBatchRequest批量请求（多个请求几乎同时发起）
3.链式请求（当前个请求结束后才能发起下一个请求）

阅读这个框架的源码我的收获是：加深了对命令模式，对Block的理解，知道了一个网络请求都需要什么元素组成，知道了网络缓存该怎么设计！

所以说多阅读源码对技术水平的提升是很有帮助的，除了能增多对本语言API的了解，其实更有意义的是它能让你接触到一些新的设计和解决问题的办法，这些都是脱离某个语言本身的东西，也是作为一名程序员所必不可少的东西。

我还在路上...
