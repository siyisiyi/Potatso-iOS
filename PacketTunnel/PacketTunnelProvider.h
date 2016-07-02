//
//  PacketTunnelProvider.h
//  PacketTunnel
//
//  Created by LEI on 12/13/15.
//  Copyright © 2015 TouchingApp. All rights reserved.
//

@import NetworkExtension;

// 这个文件是由Xcode中Application extension分类创建的，这个和主target分开打包的。这样它就有了后台常驻的可能
// 我们在app中，通过NETunnelProviderManager来控制VPN。而在app扩展中，用NEPacketTunnelProvider来实现VPN的IO。
@interface PacketTunnelProvider : NEPacketTunnelProvider

@end
