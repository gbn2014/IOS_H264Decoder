//
//  ViewController.h
//  VTDemoOniPad
//
//  Created by AJB on 16/4/25.
//  Copyright © 2016年 AJB. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SocketRocket.h"

@interface SocketViewController : UIViewController<SRWebSocketDelegate>
@property (nonatomic, strong)SRWebSocket *webSocket;
@end

