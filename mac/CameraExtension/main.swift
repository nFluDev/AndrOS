import Foundation
import CoreMediaIO

// Uzantinin giris noktasi. `startService` geri donmez.
let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
