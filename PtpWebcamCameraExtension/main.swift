//
//  main.swift
//  PtpWebcamCameraExtension
//
//  Created by Dömötör Gulyás on 02.12.2023.
//  Copyright © 2023 InRobCo. All rights reserved.
//

import Foundation
import CoreMediaIO

let providerSource = PtpWebcamCameraExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
