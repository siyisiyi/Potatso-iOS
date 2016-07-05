//
//  ProxyManager.m
//  Potatso
//
//  Created by LEI on 2/23/16.
//  Copyright © 2016 TouchingApp. All rights reserved.
//

#import "ProxyManager.h"
#import <ShadowPath/ShadowPath.h>
#import <netinet/in.h>
#import "PotatsoBase.h"

@interface ProxyManager ()
@property (nonatomic) BOOL socksProxyRunning;
@property (nonatomic) int socksProxyPort;
@property (nonatomic) BOOL httpProxyRunning;
@property (nonatomic) int httpProxyPort;
@property (nonatomic) BOOL shadowsocksProxyRunning;
@property (nonatomic) int shadowsocksProxyPort;
@property (nonatomic, copy) SocksProxyCompletion socksCompletion;
@property (nonatomic, copy) HttpProxyCompletion httpCompletion;
@property (nonatomic, copy) ShadowsocksProxyCompletion shadowsocksCompletion;
- (void)onSocksProxyCallback: (int)fd;
- (void)onHttpProxyCallback: (int)fd;
- (void)onShadowsocksCallback:(int)fd;
@end

void http_proxy_handler(int fd, void *udata) {
    ProxyManager *provider = (__bridge ProxyManager *)udata;
    [provider onHttpProxyCallback:fd];
}

void shadowsocks_handler(int fd, void *udata) {
    ProxyManager *provider = (__bridge ProxyManager *)udata;
    [provider onShadowsocksCallback:fd];
}

int sock_port (int fd) {
    struct sockaddr_in sin;
    socklen_t len = sizeof(sin);
    if (getsockname(fd, (struct sockaddr *)&sin, &len) < 0) {
        NSLog(@"getsock_port(%d) error: %s",
              fd, strerror (errno));
        return 0;
    }else{
        return ntohs(sin.sin_port);
    }
}

@implementation ProxyManager

+ (ProxyManager *)sharedManager {
    static dispatch_once_t onceToken;
    static ProxyManager *manager;
    dispatch_once(&onceToken, ^{
        manager = [ProxyManager new];
    });
    return manager;
}


// 这里拿着和远端绑定成功的本地端口和本机的一个新开端口启动本地socket服务器。启动之后会记录那个新开的端口，记录到socksProxyPort
- (void)startSocksProxy:(SocksProxyCompletion)completion
{
    self.socksCompletion = [completion copy];
    NSString *confContent = [NSString stringWithContentsOfURL:[Potatso sharedSocksConfUrl] encoding:NSUTF8StringEncoding error:nil];
    confContent = [confContent stringByReplacingOccurrencesOfString:@"${ssport}" withString:[NSString stringWithFormat:@"%d", [self shadowsocksProxyPort]]];
    int fd = [[AntinatServer sharedServer] startWithConfig:confContent];
    [self onSocksProxyCallback:fd];
}

- (void)stopSocksProxy {
    [[AntinatServer sharedServer] stop];
    self.socksProxyRunning = NO;
}

- (void)onSocksProxyCallback:(int)fd {
    NSError *error;
    if (fd > 0) {
        // 这里socksProxyPort就变成了本地服务器的监听端口。
        self.socksProxyPort = sock_port(fd);
        self.socksProxyRunning = YES;
    }else {
        error = [NSError errorWithDomain:@"com.touchingapp.potatso" code:100 userInfo:@{NSLocalizedDescriptionKey: @"Fail to start socks proxy"}];
    }
    if (self.socksCompletion) {
        self.socksCompletion(self.socksProxyPort, error);
    }
}

# pragma mark - Shadowsocks 

- (void)startShadowsocks: (ShadowsocksProxyCompletion)completion {
    self.shadowsocksCompletion = [completion copy];
    [NSThread detachNewThreadSelector:@selector(_startShadowsocks) toTarget:self withObject:nil];
}

- (void)_startShadowsocks {
    NSString *confContent = [NSString stringWithContentsOfURL:[Potatso sharedProxyConfUrl] encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *json = [confContent jsonDictionary];
    NSString *host = json[@"host"];
    NSNumber *port = json[@"port"];
    NSString *password = json[@"password"];
    NSString *authscheme = json[@"authscheme"];
    BOOL ota = [json[@"ota"] boolValue];
    if (host && port && password && authscheme) {
        profile_t profile;
        profile.remote_host = strdup([host UTF8String]);
        profile.remote_port = [port intValue];
        profile.password = strdup([password UTF8String]);
        profile.method = strdup([authscheme UTF8String]);
        profile.local_addr = "127.0.0.1";
        profile.local_port = 0;
        profile.timeout = 600;
        profile.auth = ota;
        // 这里建立远端的shadowsocks连接
        start_ss_local_server(profile, shadowsocks_handler, (__bridge void *)self);
    }else {
        if (self.shadowsocksCompletion) {
            self.shadowsocksCompletion(0, nil);
        }
        return;
    }
}

- (void)stopShadowsocks {
    // Do nothing
}

- (void)onShadowsocksCallback:(int)fd {
    NSError *error;
    if (fd > 0) {
        // 这个地方是和shadowsocks服务器绑定之后返回的local port。
        self.shadowsocksProxyPort = sock_port(fd);
        self.shadowsocksProxyRunning = YES;
    }else {
        error = [NSError errorWithDomain:@"com.touchingapp.potatso" code:100 userInfo:@{NSLocalizedDescriptionKey: @"Fail to start http proxy"}];
    }
    if (self.shadowsocksCompletion) {
        self.shadowsocksCompletion(self.shadowsocksProxyPort, error);
    }
}

# pragma mark - Http Proxy

- (void)startHttpProxy:(HttpProxyCompletion)completion {
    self.httpCompletion = [completion copy];
//    NSURL *newConfURL = [[Potatso sharedUrl] URLByAppendingPathComponent:@"http.xxx"];
    /**
     let mainConf: [(String, AnyObject)] = [("confdir", confDirUrl.path!),
     ("templdir", templateDirPath),
     ("logdir", logDir),
     ("listen-address", "127.0.0.1:0"),
     ("toggle", 1),
     ("enable-remote-toggle", 0),
     ("enable-remote-http-toggle", 0),
     ("enable-edit-actions", 0),
     ("enforce-blocks", 0),
     ("buffer-limit", 512),
     ("enable-proxy-authentication-forwarding", 0),
     ("accept-intercepted-requests", 0),
     ("allow-cgi-request-crunching", 0),
     ("split-large-forms", 0),
     ("keep-alive-timeout", 5),
     ("tolerate-pipelining", 1),
     ("socket-timeout", 300),
     // ("debug", 1024+65536+1),
     ("debug", 8192),
     ("actionsfile", "user.action"),
     (defaultRouteString, defaultProxyString),／／ 127.0.0.1:${ssport}
     // ("debug", 131071)
     ]
     */
    NSURL *confURL = [Potatso sharedHttpProxyConfUrl];
    // 这里拿出来的是如上所示的数组拼出来的字符串
    NSString *content = [NSString stringWithContentsOfURL:confURL encoding:NSUTF8StringEncoding error:nil];
    content = [content stringByReplacingOccurrencesOfString:@"${ssport}" withString:[NSString stringWithFormat:@"%d", self.shadowsocksProxyPort]];
    [content writeToURL:confURL atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSURL *actionURL = [[Potatso sharedUrl] URLByAppendingPathComponent:@"httpconf/user.action"];
    content = [NSString stringWithContentsOfURL:actionURL encoding:NSUTF8StringEncoding error:nil];
    content = [content stringByReplacingOccurrencesOfString:@"${ssport}" withString:[NSString stringWithFormat:@"%d", self.shadowsocksProxyPort]];
    // content中包含的是http代理的过滤规则
    [content writeToURL:actionURL atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [NSThread detachNewThreadSelector:@selector(_startHttpProxy:) toTarget:self withObject:confURL];
}

// 这是把mainConf丢进去了，包含了local ss地址和端口、连接timeout等信息。
// 也包含了forward-socks5 127.0.0.1:${ssport} .这样的规则，将自己拦截到的流量转发到之前已建立的shadowsocks连接的本地端口。
- (void)_startHttpProxy: (NSURL *)confURL
{
    // 这里用到privoxy，是一个http代理工具，能实现链式转发，就是说他收到一个http请求能够将请求转发给另一个http代理, provixy也可以将http转换成socks交给一个socks代理
    /**
     HTTP 代理转发的语法如下（把该语法添加在“主配置文件”尾部）：
     forward target_pattern http_proxy:port
     
     　　语法解释：
     　　该命令分3段，各段之间用空格分开（可以用单个空格，也可以多个空格）
     　　第1段的 forward 是固定的，表示：这是 HTTP 转发
     　　第2段的 target_pattern 是个变量，表示：这次转发只针对特定模式的 HTTP 访问目标
     　　第3段的 http_proxy:port 也是变量，表示：要转发给某个 HTTP 代理（IP 冒号 端口）。如果“第3段”只写一个单独的小数点，表示直连（不走代理）。
     */
    /**
     　SOCKS 代理转发，包括如下几种语法：
     forward-socks4 target_pattern socks_proxy:port http_proxy:port
     forward-socks4a target_pattern socks_proxy:port http_proxy:port
     forward-socks5 target_pattern socks_proxy:port http_proxy:port
     forward-socks5t target_pattern socks_proxy:port http_proxy:port
     */
    /**
     语法解释：
     　　该命令分4段，各段之间用空格分开（可以用单个空格，也可以多个空格）
     　　第1段是以 forward 开头的，表示 SOCKS 转发的类型。目前支持 4 种类型。
     前面3种（forward-socks4 forward-socks4a forward-socks5）分别对应不同版本的 SOCKS 协议。
     最后一种 forward-socks5t 比较特殊，是基于 SOCKS5 协议版本，但是加入针对 TOR 的扩展支持（优化了性能）。只有转发给 TOR 的 SOCKS 代理，才需要用这个类型。
     　　第2段的 target_pattern 是个变量，表示：这次转发只针对特定模式的 HTTP 访问目标
     　　第3段的 socks_proxy:port 也是变量，表示：要转发给某个 SOCKS 代理（IP 冒号 端口）
     　　第4段的 http_proxy:port 也是变量，表示：在经由前面的 SOCKS 代理之后，再转发给某个 HTTP 代理（IP 冒号 端口）
     
     　　举例1
     　　如果你本机安装了 TOR Browser 软件包，可以使用如下语法，把 Privoxy 收到的 HTTP 请求转发给 TOR Browser 内置的 SOCKS 代理。
        forward-socks5 / 127.0.0.1:9150 .
     */
    // 这个方法是作者扩展出来的，并不是privoxy本身自带的
    shadowpath_main(strdup([[confURL path] UTF8String]), http_proxy_handler, (__bridge void *)self);
}

- (void)stopHttpProxy {
//    polipoExit();
//    self.httpProxyRunning = NO;
}

- (void)onHttpProxyCallback:(int)fd {
    NSError *error;
    if (fd > 0) {
        self.httpProxyPort = sock_port(fd);
        self.httpProxyRunning = YES;
    }else {
        error = [NSError errorWithDomain:@"com.touchingapp.potatso" code:100 userInfo:@{NSLocalizedDescriptionKey: @"Fail to start http proxy"}];
    }
    if (self.httpCompletion) {
        self.httpCompletion(self.httpProxyPort, error);
    }
}

@end

