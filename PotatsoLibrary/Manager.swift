//
//  Manager.swift
//  Potatso
//
//  Created by LEI on 4/7/16.
//  Copyright © 2016 TouchingApp. All rights reserved.
//

import PotatsoBase
import PotatsoModel
import RealmSwift
import KissXML
import NetworkExtension
import ICSMainFramework
import MMWormhole

public enum ManagerError: Error {
    case InvalidProvider
    case VPNStartFail
}

public enum VPNStatus {
    case Off
    case Connecting
    case On
    case Disconnecting
}


public let kDefaultGroupIdentifier = "defaultGroup"
public let kDefaultGroupName = "defaultGroupName"
private let statusIdentifier = "status"
public let kProxyServiceVPNStatusNotification = "kProxyServiceVPNStatusNotification"

public class Manager {
    
    public static let sharedManager = Manager()
    
    public private(set) var vpnStatus = VPNStatus.Off {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: kProxyServiceVPNStatusNotification), object: nil)
        }
    }
    
    public let wormhole = MMWormhole(applicationGroupIdentifier: sharedGroupIdentifier, optionalDirectory: "wormhole")

    var observerAdded: Bool = false
    
    public private(set) var defaultConfigGroup: ConfigurationGroup!

    private init() {
        
        loadProviderManager { (manager) -> Void in
            if let manager = manager {
                self.updateVPNStatus(manager: manager)
            }
        }
        addVPNStatusObserver()
    }
    
    func addVPNStatusObserver() {
        guard !observerAdded else{
            return
        }
        loadProviderManager { [unowned self] (manager) -> Void in
            if let manager = manager {
                self.observerAdded = true
                NotificationCenter.default.addObserver(forName: NSNotification.Name.NEVPNStatusDidChange, object: manager.connection, queue: OperationQueue.main, using: { [unowned self] (notification) -> Void in
                    self.updateVPNStatus(manager: manager)
                })
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func updateVPNStatus(manager: NEVPNManager) {
        switch manager.connection.status {
        case .connected:
            self.vpnStatus = .On
        case .connecting, .reasserting:
            self.vpnStatus = .Connecting
        case .disconnecting:
            self.vpnStatus = .Disconnecting
        case .disconnected, .invalid:
            self.vpnStatus = .Off
        }
        
    }

    // 在setDefaultConfigGroup方法中已经将DNS、本地sock5、远端shadowsocks账号存起来了
    public func switchVPN(completion: ((NETunnelProviderManager?, Error?) -> Void)? = nil) {
        loadProviderManager { [unowned self] (manager) in
            if let manager = manager
            {
                self.updateVPNStatus(manager: manager)
            }
            let current = self.vpnStatus
            guard current != .Connecting && current != .Disconnecting else {
                return
            }
            
            if current == .Off {
                self.startVPN { (manager, error) -> Void in
                    completion?(manager, error)
                }
            }else {
                self.stopVPN()
                completion?(nil, nil)
            }

        }
    }
    
    public func switchVPNFromTodayWidget(context: NSExtensionContext) {
        if let url = NSURL(string: "potatso://switch") {
            context.open(url as URL, completionHandler: nil)
        }
    }
    
    public func setup() throws {
        setupDefaultReaml()
        try initDefaultConfigGroup()
        do {
            try copyGEOIPData()
            try copyTemplateData()
        }catch{
            print("copy fail")
        }
    }
    
    func copyGEOIPData() throws {
        for country in ["CN"] {
            guard let fromURL = Bundle.main.url(forResource: "geoip-\(country)", withExtension: "data") else {
                return
            }
            let toURL = Potatso.sharedUrl().appendingPathComponent("httpconf/geoip-\(country).data")
            if FileManager.default.fileExists(atPath: fromURL.path) {
                if FileManager.default.fileExists(atPath: toURL.path) {
                    try FileManager.default.removeItem(at: toURL)
                }
                try FileManager.default.copyItem(at: fromURL, to: toURL)
            }
        }
    }

    func copyTemplateData() throws {
        guard let bundleURL = Bundle.main.url(forResource: "template", withExtension: "bundle") else {
            return
        }
        let fm = FileManager.default
        let toDirectoryURL = Potatso.sharedUrl().appendingPathComponent("httptemplate")
        if !fm.fileExists(atPath: toDirectoryURL.path) {
            try fm.createDirectory(at: toDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        for file in try fm.contentsOfDirectory(atPath: bundleURL.path) {
            let destURL = toDirectoryURL.appendingPathComponent(file)
            let dataURL = bundleURL.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: dataURL.path) {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try fm.copyItem(at: dataURL, to: destURL)
            }
        }
    }

    public func initDefaultConfigGroup() throws {
        if let groupUUID = Potatso.sharedUserDefaults().string(forKey: kDefaultGroupIdentifier), let group = defaultRealm.objects(ConfigurationGroup).filter("uuid = '\(groupUUID)'").first
        {
            try setDefaultConfigGroup(group: group)
        }
        else
        {
            var group: ConfigurationGroup
            if let g = defaultRealm.objects(ConfigurationGroup).first {
                group = g
            }else {
                group = ConfigurationGroup()
                group.name = "Default".localized()
                do {
                    try defaultRealm.write {
                        defaultRealm.add(group)
                    }
                }catch {
                    fatalError("Fail to generate default group")
                }
            }
            try setDefaultConfigGroup(group: group)
        }
    }
    
    
    // 这里是为之后连接VPN做准备, group对象包含了shadossock连接的配置信息：服务器信息、过滤条件、名字、是否全局等
    public func setDefaultConfigGroup(group: ConfigurationGroup) throws
    {
        defaultConfigGroup = group
        try regenerateConfigFiles()
        let uuid = defaultConfigGroup.uuid
        let name = defaultConfigGroup.name
        Potatso.sharedUserDefaults().set(uuid, forKey: kDefaultGroupIdentifier)
        Potatso.sharedUserDefaults().set(name, forKey: kDefaultGroupName)
        Potatso.sharedUserDefaults().synchronize()
    }
    
    public func regenerateConfigFiles() throws {
        // 保存dns设置 保存到了这里：sharedGeneralConfUrl
        try generateGeneralConfig()
        // 保存一个sock5连接设置 保存到了这里：sharedSocksConfUrl
        try generateSocksConfig()
        // 保存shadowsock的配置 保存到了这里：sharedProxyConfUrl
        try generateShadowsocksConfig()
        // 这里似乎是设置http的过滤需求 保存到了这里包含了本地的监听端口127.0.0.1:0、keepalive的时间、sock－time－out时间等
        // 另外还解析了自定义的过滤规则以及本来就带有的规则
        try generateHttpProxyConfig()
    }

}

extension ConfigurationGroup {

    public var isDefault: Bool {
        let defaultUUID = Manager.sharedManager.defaultConfigGroup.uuid
        let isDefault = defaultUUID == uuid
        return isDefault
    }
    
}

extension Manager {
    
    var upstreamProxy: Proxy? {
        return defaultConfigGroup.proxies.first
    }
    
    var defaultToProxy: Bool {
        return defaultConfigGroup.defaultToProxy ?? false
    }
    
    func generateGeneralConfig() throws {
        let confURL = Potatso.sharedGeneralConfUrl()
        let json: NSDictionary = ["dns": defaultConfigGroup.dns ?? ""]
        try json.jsonString()?.write(to: confURL, atomically: true, encoding: String.Encoding.utf8)
    }
    
    func generateSocksConfig() throws {
        let root = NSXMLElement.element(withName: "antinatconfig") as! NSXMLElement
        let interface = NSXMLElement.element(withName: "interface", children: nil, attributes: [NSXMLNode.attribute(withName: "value", stringValue: "127.0.0.1") as! DDXMLNode]) as! NSXMLElement
        root.addChild(interface)
        
        let port = NSXMLElement.element(withName: "port", children: nil, attributes: [NSXMLNode.attribute(withName: "value", stringValue: "0") as! DDXMLNode])  as! NSXMLElement
        root.addChild(port)
        
        let maxbindwait = NSXMLElement.element(withName: "maxbindwait", children: nil, attributes: [NSXMLNode.attribute(withName: "value", stringValue: "10") as! DDXMLNode]) as! NSXMLElement
        root.addChild(maxbindwait)
        
        
        let authchoice = NSXMLElement.element(withName: "authchoice") as! NSXMLElement
        let select = NSXMLElement.element(withName: "select", children: nil, attributes: [NSXMLNode.attribute(withName: "mechanism", stringValue: "anonymous") as! DDXMLNode])  as! NSXMLElement
        
        authchoice.addChild(select)
        root.addChild(authchoice)
        
        let filter = NSXMLElement.element(withName: "filter") as! NSXMLElement
        if let upstreamProxy = upstreamProxy
        {
            let chain = NSXMLElement.element(withName: "chain", children: nil, attributes: [NSXMLNode.attribute(withName: "name", stringValue: upstreamProxy.name) as! DDXMLNode]) as! NSXMLElement
            switch upstreamProxy.type
            {
                case .Shadowsocks:
                    let uriString = "socks5://127.0.0.1:${ssport}"
                    let uri = NSXMLElement.element(withName: "uri", children: nil, attributes: [NSXMLNode.attribute(withName: "value", stringValue: uriString) as! DDXMLNode]) as! NSXMLElement
                    chain.addChild(uri)
                    let authscheme = NSXMLElement.element(withName: "authscheme", children: nil, attributes: [NSXMLNode.attribute(withName: "value", stringValue: "anonymous") as! DDXMLNode]) as! NSXMLElement
                    chain.addChild(authscheme)
                default:
                    break
            }
            root.addChild(chain)
        }
        
        let accept = NSXMLElement.element(withName: "accept") as! NSXMLElement
        filter.addChild(accept)
        root.addChild(filter)
        
        /**
         生成的xml的格式参见generatedXML.xml 如下保存到了sharedSocksConfUrl中。
         */
        let socksConf = root.xmlString
        try socksConf.write(to: Potatso.sharedSocksConfUrl(), atomically: true, encoding: String.Encoding.utf8)
    }
    
    func generateShadowsocksConfig() throws {
        // 拿出最新的存储的Proxy
        guard let upstreamProxy = upstreamProxy, upstreamProxy.type == .Shadowsocks else {
            return
        }
        
        let confURL = Potatso.sharedProxyConfUrl()
        let json = ["host": upstreamProxy.host, "port": upstreamProxy.port, "password": upstreamProxy.password ?? "", "authscheme": upstreamProxy.authscheme ?? "", "ota": upstreamProxy.ota] as [String : Any]
//        [
//            "host"        : "remote shadowsocks server address",
//            "port"        : "remote shadowsocks server port",
//            "password"    : "remote shadowsocks password",
//            "authscheme"  : "encryp type",
//            "ota"         : "isota"
//        ]

        do{
            let jsonData = try JSONSerialization.data(withJSONObject: json, options: JSONSerialization.WritingOptions.prettyPrinted)
            if let jsonString = String(data: jsonData, encoding: .utf8){
                try jsonString.write(to: confURL, atomically: true, encoding: .utf8)
            }
        }
        catch{
        }
    }
    
    func generateHttpProxyConfig() throws {
        let rootUrl = Potatso.sharedUrl()
        let confDirUrl = rootUrl.appendingPathComponent("httpconf")
        let templateDirPath = rootUrl.appendingPathComponent("httptemplate").path
        let temporaryDirPath = rootUrl.appendingPathComponent("httptemporary").path
        let logDir = rootUrl.appendingPathComponent("log").path
        for p in [confDirUrl.path, templateDirPath, temporaryDirPath, logDir] {
            if !FileManager.default.fileExists(atPath: p) {
                _ = try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true, attributes: nil)
            }
        }
        let directString = "forward ."
        var proxyString = directString
        var defaultRouteString = "default-route"
        var defaultProxyString = "."

        if let upstreamProxy = upstreamProxy {
            switch upstreamProxy.type {
            case .Shadowsocks:
                proxyString = "forward-socks5 127.0.0.1:${ssport} ."
                if defaultToProxy {
                    defaultRouteString = "default-route-socks5"
                    defaultProxyString = "127.0.0.1:${ssport} ."
                }
            default:
                break
            }
        }
/**
                                proxyString               defaultRouteString       defaultProxyString
 
 undecided value:                 forward.   				default-route			      .
 
 shadowsocks value:   forward-socks5 127.0.0.1:${ssport}   default-route-socks5     127.0.0.1:${ssport}
 */
        
        // 这个数组实际上是用来规定了provixy的配置信息，使通过provixy的http流量转发给socks服务器
        let mainConf: [(String, AnyObject)] = [("confdir", confDirUrl.path as AnyObject),
                                             ("templdir", templateDirPath as AnyObject),
                                             ("logdir", logDir as AnyObject),
                                             ("listen-address", "127.0.0.1:0" as AnyObject),
                                             ("toggle", 1 as AnyObject),
                                             ("enable-remote-toggle", 0 as AnyObject),
                                             ("enable-remote-http-toggle", 0 as AnyObject),
                                             ("enable-edit-actions", 0 as AnyObject),
                                             ("enforce-blocks", 0 as AnyObject),
                                             ("buffer-limit", 512 as AnyObject),
                                             ("enable-proxy-authentication-forwarding", 0 as AnyObject),
                                             ("accept-intercepted-requests", 0 as AnyObject),
                                             ("allow-cgi-request-crunching", 0 as AnyObject),
                                             ("split-large-forms", 0 as AnyObject),
                                             ("keep-alive-timeout", 5 as AnyObject),
                                             ("tolerate-pipelining", 1 as AnyObject),
                                             ("socket-timeout", 300 as AnyObject),
//                                             ("debug", 1024+65536+1),
                                             ("debug", 8192 as AnyObject),
                                             ("actionsfile", "user.action" as AnyObject),
                                             (defaultRouteString, defaultProxyString as AnyObject),
//                                             ("debug", 131071)
                                             ]
        var actionContent: [String] = []
        var forwardIPDirectContent: [String] = []
        var forwardIPProxyContent: [String] = []
        var forwardURLDirectContent: [String] = []
        var forwardURLProxyContent: [String] = []
        var blockContent: [String] = []
        let rules = defaultConfigGroup.ruleSets.map({ $0.rules }).flatMap({ $0 })
        for rule in rules
        {
            // 把规则拿出来,区分不同的过滤规则，通过地理位置过滤，通过ip地址过滤，通过域名匹配规则过滤
            // 分别装进三个数组中一个不走代理，一个走代理，一个直接拒绝
            if rule.type == .GeoIP
            {
                switch rule.action
                {
                    case .Direct:
                        if (!forwardIPDirectContent.contains(rule.value))
                        {
                            forwardIPDirectContent.append(rule.value)
                        }
                    case .Proxy:
                        if (!forwardIPProxyContent.contains(rule.value))
                        {
                            forwardIPProxyContent.append(rule.value)
                        }
                    case .Reject:
                        break
                }
            }
            else if (rule.type == .IPCIDR)
            {
                switch rule.action
                {
                    case .Direct:
                        forwardIPDirectContent.append(rule.value)
                    case .Proxy:
                        forwardIPProxyContent.append(rule.value)
                    case .Reject:
                        break
                }
            }
            else
            {
                switch rule.action
                {
                    case .Direct:
                        forwardURLDirectContent.append(rule.pattern)
                        break
                    case .Proxy:
                        forwardURLProxyContent.append(rule.pattern)
                        break
                    case .Reject:
                        blockContent.append(rule.pattern)
                }
            }
        }

        let mainContent = mainConf.map { "\($0) \($1)"}.joined(separator: "\n")
        try mainContent.write(to: Potatso.sharedHttpProxyConfUrl(), atomically: true, encoding: String.Encoding.utf8)

        if let _ = upstreamProxy
        {
            if forwardURLProxyContent.count > 0
            {
                actionContent.append("{+forward-override{\(proxyString)}}")  // {+forward-override{forward.}}
                // 将通过域名走proxy的代理的匹配规则装到这个这个数组里面
                actionContent.append(contentsOf: forwardURLProxyContent)
            }
            if forwardIPProxyContent.count > 0
            {
                actionContent.append("{+forward-resolved-ip{\(proxyString)}}")  // {+forward-resolved-ip{forward.}}
                // 将通过ip走proxy的代理的匹配规则装到这个这个数组里面
                actionContent.append(contentsOf: forwardIPProxyContent)
                // 将受DNS污染的ip也装进来
                actionContent.append(contentsOf: Pollution.dnsList.map({ $0 + "/32" }))
            }
        }

        if forwardURLDirectContent.count > 0
        {
            // 可以直连的域名再加进来
            actionContent.append("{+forward-override{\(directString)}}")
            actionContent.append(contentsOf: forwardURLDirectContent)
        }

        if forwardIPDirectContent.count > 0
        {
            // 可以直连的ip加进来
            actionContent.append("{+forward-resolved-ip{\(directString)}}")
            actionContent.append(contentsOf: forwardIPDirectContent)
        }

        if blockContent.count > 0
        {
            // 直接屏蔽掉的ip加进来
            actionContent.append("{+block{Blocked} +handle-as-empty-document}")
            actionContent.append(contentsOf: blockContent)
        }

        // 将数组中所有的元素用换行符拼接起来组成字符串 然后存起来
        let userActionString = actionContent.joined(separator: "\n")
        let userActionUrl = confDirUrl.appendingPathComponent("user.action")
        try userActionString.write(toFile: userActionUrl.path, atomically: true, encoding: String.Encoding.utf8)
    }

}

extension Manager {
    
    public func isVPNStarted(complete: @escaping (Bool, NETunnelProviderManager?) -> Void) {
        loadProviderManager { (manager) -> Void in
            if let manager = manager {
                complete(manager.connection.status == .connected, manager)
            }else{
                complete(false, nil)
            }
        }
    }
    
    
    // MARK: 正式连接VPN
    public func startVPN(complete: ((NETunnelProviderManager?, Error?) -> Void)? = nil) {
        startVPNWithOptions(options: nil, complete: complete)
    }
    
    private func startVPNWithOptions(options: [String : NSObject]?, complete: ((NETunnelProviderManager?, Error?) -> Void)? = nil) {
        // regenerate config files
        do
        {
            try Manager.sharedManager.regenerateConfigFiles()
        }
        catch
        {
            complete?(nil, error)
            return
        }
        
        loadAndCreateProviderManager { (manager, error) -> Void in
            if let error = error
            {
                complete?(nil, error)
            }
            else
            {
                
                guard let manager = manager else
                {
                    complete?(nil, ManagerError.InvalidProvider)
                    return
                }
                // 拿到了manager开启vpn连接
                if manager.connection.status == .disconnected || manager.connection.status == .invalid
                {
                    do
                    {
                        try manager.connection.startVPNTunnel(options: options)
                        self.addVPNStatusObserver()
                        complete?(manager, nil)
                    }
                    catch
                    {
                        complete?(nil, error)
                    }
                }
                else
                {
                    self.addVPNStatusObserver()
                    complete?(manager, nil)
                }
            }
        }
    }
    
    public func stopVPN() {
        // Stop provider
        
        
        loadProviderManager { (manager) -> Void in
            guard let manager = manager else {
                return
            }
            manager.connection.stopVPNTunnel()
        }
    }
    
    public func postMessage() {
        loadProviderManager { (manager) -> Void in
            if let session = manager?.connection as? NETunnelProviderSession,
                let message = "Hello".data(using: String.Encoding.utf8), manager?.connection.status != .invalid
            {
                do {
                    try session.sendProviderMessage(message) { response in
                        
                    }
                } catch {
                    print("Failed to send a message to the provider")
                }
            }
        }
    }
    
    
    // 这个方法是去Preferences中去找看有没有之前保存了的configuration，如果没有就创建一个.
    // 其中manager类是NETunnelProviderManager类，之所以是这个类，因为官方文档写出来了，这个类具有自定义协议的能力
    // Like its super class NEVPNManager, the NETunnelProviderManager class is used to configure and control VPN connections. The difference is that NETunnelProviderManager is used to to configure and control VPN connections that use a custom VPN protocol.
    private func loadAndCreateProviderManager(complete: @escaping (NETunnelProviderManager?, Error?) -> Void ) {
        
        
        NETunnelProviderManager.loadAllFromPreferences { [unowned self] (managers, error) -> Void in
            
            // 这里拿到回调之后的manager做事情
            if let managers = managers {
                let manager: NETunnelProviderManager
                if managers.count > 0
                {
                    manager = managers[0]
                }
                else
                {
                    manager = self.createProviderManager()
                }
                manager.isEnabled = true
                manager.localizedDescription = AppEnv.appName
                // vpn server 的地址
                manager.protocolConfiguration?.serverAddress = AppEnv.appName
                manager.isOnDemandEnabled = true
                let quickStartRule = NEOnDemandRuleEvaluateConnection()
                // 当请求potatso.com的时候就会自动连接vpn
                quickStartRule.connectionRules = [NEEvaluateConnectionRule(matchDomains: ["potatso.com"], andAction: NEEvaluateConnectionRuleAction.connectIfNeeded)]
                manager.onDemandRules = [quickStartRule]
                // 这里仅仅是将一个 NETunnelProviderManager 类存进去，
                // 类本身并不包含代理信息，会在PacketTunnelProvider中的startTunnelWithOptions方法中有回调，在回调的时候建立本地的和远端shadowsocks的连接，以及手机上所有流量从一个端口出去。
                manager.saveToPreferences(completionHandler: { (error) -> Void in
                    if let error = error
                    {
                        complete(nil, error)
                    }
                    else
                    {
                        manager.loadFromPreferences(completionHandler: { (error) -> Void in
                            if let error = error
                            {
                                complete(nil, error)
                            }
                            else
                            {
                                complete(manager, nil)
                            }
                        })
                    }
                })
            }else{
                complete(nil, error)
            }
        }
    }
    
    public func loadProviderManager(complete: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) -> Void in
            
            if let managers = managers
            {
                if managers.count > 0
                {
                    let manager = managers[0]
                    complete(manager)
                    return
                }
            }
            complete(nil)
        }
    }
    
    
    
    // 创建一个manager 这个manager是一个 NETunnelProviderManager类
    private func createProviderManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = NETunnelProviderProtocol()
        return manager
    }
}
