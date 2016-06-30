//
//  PacketTunnelProvider.h
//  PacketTunnel
//
//  Created by LEI on 12/13/15.
//  Copyright © 2015 TouchingApp. All rights reserved.
//

@import NetworkExtension;

// 这个类已经在info plist中注册了，所以当在其他地方调用loadAllFromPreferencesWithCompletionHandler 的时候系统自动会询问这个类

@interface PacketTunnelProvider : NEPacketTunnelProvider

@end
