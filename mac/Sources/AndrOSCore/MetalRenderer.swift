import Foundation
import Metal
import MetalKit
import CoreVideo
import QuartzCore
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// NV12 -> RGB donusumu, Catmull-Rom olceklendirme ve renk ayarlari.
/// Shader runtime'da derlenir; Xcode gerekmez.
public final class MetalRenderer {

    public struct Params {
        /// Doygunluk. 1.0 = matematiksel olarak sadik.
        /// Telefonun IPS paneli kendi kontrast/doygunlugunu katiyor ve
        /// yakalanan veride bu yok; 1.15 o farki telafi ediyor.
        public var saturation: Float = 1.15
        /// Unsharp mask. Kaynak 720p ve buyutuluyor, bu yuzden belirgin.
        public var sharpen: Float = 0.45
        public var contrast: Float = 1.05
        public var gamma: Float = 1.0
        public init() {}
    }

    public var params = Params()

    /// true ise goruntu drawable'i tamamen doldurur (siyah kenarlik YOK,
    /// oran bozulur). ALT + tam ekran bunu kullanir. Normal tam ekran ve
    /// pencere modunda false: oran korunur, artan alan siyah kalir.
    public var stretchToFill = false

    /// Encoder'lar renk araligini YANLIS etiketleyebiliyor (olculdu: MediaTek
    /// color-range=1 verilince akisi FULL isaretliyor ama veriyi limited
    /// birakiyor). Bu yuzden etikete guvenmeyip ilk karelerde gercek luma
    /// dagilimina bakiyoruz. Yanlis karar dogrudan "soluk goruntu" demek.
    private var detectedFullRange: Bool?
    private var detectionSamples = 0

    /// Gercek piksel verisinden renk araligini tespit eder.
    ///
    /// Dikkat: kayipli sikistirma, LIMITED icerikte bile birkac pikseli
    /// 16-235 disina tasirabilir (ringing). Bu yuzden esik yuksek tutulmali
    /// ve karar tek kareye degil BIRIKIME dayanmali. Yanlis "FULL" karari
    /// genisletmeyi atlatir ve goruntuyu dogrudan soluklastirir.
    private var accOutside = 0
    private var accTotal = 0

    private func resolveRange(_ pb: CVPixelBuffer, taggedFull: Bool) -> Bool {
        if let d = detectedFullRange { return d }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let w = CVPixelBufferGetWidthOfPlane(pb, 0)
            let h = CVPixelBufferGetHeightOfPlane(pb, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in Swift.stride(from: 0, to: h, by: 4) {
                for x in Swift.stride(from: 0, to: w, by: 4) {
                    let v = ptr[y * rowBytes + x]
                    if v < 16 || v > 235 { accOutside += 1 }
                    accTotal += 1
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        detectionSamples += 1
        guard detectionSamples >= 15, accTotal > 0 else {
            // Karar verilene kadar etikete uy (zorlama yapmadigimizda dogru).
            return taggedFull
        }

        let ratio = Double(accOutside) / Double(accTotal)
        // %3: sikistirma gurultusunun cok uzerinde, gercek full-range
        // icerigin ise rahatlikla asacagi bir esik.
        let isFull = ratio > 0.03
        detectedFullRange = isFull
        Log.write(String(format: "renk araligi TESPIT: %@ (tasma %%%.2f, etiket=%@)",
                         isFull ? "FULL" : "LIMITED", ratio * 100,
                         taggedFull ? "full" : "limited"))
        return isFull
    }

    public func resetRangeDetection() {
        detectedFullRange = nil
        detectionSamples = 0
        accOutside = 0
        accTotal = 0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!
    private let sampler: MTLSamplerState

    public init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.queue = q

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let smp = dev.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = smp

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache) == kCVReturnSuccess,
              let c = cache else { return nil }
        self.textureCache = c

        do {
            let lib = try dev.makeLibrary(source: MetalRenderer.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "fullscreenVS")
            desc.fragmentFunction = lib.makeFunction(name: "nv12FS")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("AndrOS: shader derlenemedi: \(error)")
            return nil
        }
    }

    public var mtlDevice: MTLDevice { device }

    /// Bir CVPixelBuffer'i verilen katmana cizer.
    ///
    /// EN-BOY ORANI: shader tam ekran ucgen ciziyor, yani drawable'i tamamen
    /// dolduruyor. Orani korumak icin VIEWPORT'u aspect-fit dikdortgene
    /// kisitliyoruz; disinda kalan alan clear rengiyle (siyah) doluyor.
    public func render(_ pixelBuffer: CVPixelBuffer, to layer: CAMetalLayer) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0, let drawable = layer.nextDrawable() else { return }

        // Akisin renk araligi: 420f = full, 420v = video(limited).
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let tagged = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isFullRange = resolveRange(pixelBuffer, taggedFull: tagged)

        guard let yTex = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm),
              let cTex = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm) else { return }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }

        // Viewport: fit = orani koru (siyah kenarlik), fill = geri kalan yok
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        if stretchToFill {
            enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: dw, height: dh, znear: 0, zfar: 1))
        } else {
            let scale = Swift.min(dw / Double(w), dh / Double(h))
            let vw = Double(w) * scale, vh = Double(h) * scale
            enc.setViewport(MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2,
                                        width: vw, height: vh, znear: 0, zfar: 1))
        }

        var u = Uniforms(texSize: SIMD2<Float>(Float(w), Float(h)),
                         saturation: params.saturation, sharpen: params.sharpen,
                         contrast: params.contrast, gamma: params.gamma,
                         fullRange: isFullRange ? 1 : 0)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(cTex, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// Ayni hatti offscreen bir dokuya cizer (dogrulama/ekran goruntusu icin).
    public func renderToTexture(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .managed
        guard let target = device.makeTexture(descriptor: td) else { return nil }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isFullRange = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        guard let yTex = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm),
              let cTex = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm) else { return nil }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        var u = Uniforms(texSize: SIMD2<Float>(Float(w), Float(h)),
                         saturation: params.saturation, sharpen: params.sharpen,
                         contrast: params.contrast, gamma: params.gamma,
                         fullRange: isFullRange ? 1 : 0)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(cTex, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: target); blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        return target
    }

    /// Cizilmis dokuyu PNG verisine cevirir (panoya koymak icin).
    public static func pngData(_ tex: MTLTexture) -> Data? {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in Swift.stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Cizilmis dokuyu PNG olarak kaydeder.
    public static func savePNG(_ tex: MTLTexture, to url: URL) -> Bool {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA -> RGBA
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes.swapAt(i, i + 2)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    private struct Uniforms {
        var texSize: SIMD2<Float>
        var saturation: Float
        var sharpen: Float
        var contrast: Float
        var gamma: Float
        var fullRange: UInt32
    }

    private func makeTexture(_ pb: CVPixelBuffer, plane: Int,
                             format: MTLPixelFormat) -> MTLTexture? {
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var out: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil, format, w, h, plane, &out)
        guard st == kCVReturnSuccess, let t = out else { return nil }
        return CVMetalTextureGetTexture(t)
    }

    // MARK: - Shader

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 texSize;
        float  saturation;
        float  sharpen;
        float  contrast;
        float  gamma;
        uint   fullRange;
    };

    struct VOut { float4 pos [[position]]; float2 uv; };

    // Tek ucgenle tam ekran kaplama (quad'dan ucuz)
    vertex VOut fullscreenVS(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.uv  = p;
        o.pos = float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
        return o;
    }

    // Catmull-Rom agirliklari: buyutmede bilinear'dan belirgin daha keskin,
    // Lanczos'un halkalanma (ringing) sorunu olmadan.
    static inline float4 crWeights(float t) {
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.5 * float4(-t3 + 2.0*t2 - t,
                             3.0*t3 - 5.0*t2 + 2.0,
                            -3.0*t3 + 4.0*t2 + t,
                             t3 - t2);
    }

    // Catmull-Rom, 9 bilinear tap ile (16 nokta ornekleme yerine).
    // Donanimin bilinear filtresi agirliklarin yarisini bedavaya yapar:
    // ayni gorsel sonuc, ~%45 daha az doku erisimi.
    static inline float sampleLumaCR(texture2d<float> tex, sampler s,
                                     float2 uv, float2 size) {
        float2 samplePos = uv * size;
        float2 texPos1 = floor(samplePos - 0.5) + 0.5;
        float2 f  = samplePos - texPos1;

        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);

        float2 w12 = w1 + w2;
        float2 off12 = w2 / w12;

        float2 p0  = (texPos1 - 1.0) / size;
        float2 p3  = (texPos1 + 2.0) / size;
        float2 p12 = (texPos1 + off12) / size;

        float r = 0.0;
        r += tex.sample(s, float2(p0.x,  p0.y )).r * w0.x  * w0.y;
        r += tex.sample(s, float2(p12.x, p0.y )).r * w12.x * w0.y;
        r += tex.sample(s, float2(p3.x,  p0.y )).r * w3.x  * w0.y;
        r += tex.sample(s, float2(p0.x,  p12.y)).r * w0.x  * w12.y;
        r += tex.sample(s, float2(p12.x, p12.y)).r * w12.x * w12.y;
        r += tex.sample(s, float2(p3.x,  p12.y)).r * w3.x  * w12.y;
        r += tex.sample(s, float2(p0.x,  p3.y )).r * w0.x  * w3.y;
        r += tex.sample(s, float2(p12.x, p3.y )).r * w12.x * w3.y;
        r += tex.sample(s, float2(p3.x,  p3.y )).r * w3.x  * w3.y;
        return r;
    }

    // AMD CAS (Contrast Adaptive Sharpening) mantigi.
    // Naif unsharp mask her yeri esit keskinlestirip kenarlarda halo
    // uretiyordu. CAS, zaten kontrastli bolgelerde keskinlestirmeyi kisar;
    // duz alanlarda ise daha cok detay cikarir. 720p -> 1080p buyutmede fark eder.
    static inline float casSharpen(float e, float b, float d, float f, float h,
                                   float amount) {
        float mn = min(min(min(b, d), min(f, h)), e);
        float mx = max(max(max(b, d), max(f, h)), e);
        // Ne kadar yer var? Doygunluga yakin bolgelerde az, duz bolgelerde cok.
        float amp = clamp(min(mn, 1.0 - mx) / max(mx, 1.0/64.0), 0.0, 1.0);
        amp = sqrt(amp);
        float w = amp * mix(-0.125, -0.2, clamp(amount, 0.0, 1.0)) * amount;
        float sum = (b + d + f + h) * w + e;
        return clamp(sum / (1.0 + 4.0 * w), 0.0, 1.0);
    }

    fragment float4 nv12FS(VOut in [[stage_in]],
                           texture2d<float> yTex [[texture(0)]],
                           texture2d<float> cTex [[texture(1)]],
                           sampler samp [[sampler(0)]],
                           constant Uniforms &u [[buffer(0)]]) {
        float  Y  = sampleLumaCR(yTex, samp, in.uv, u.texSize);
        float2 C  = cTex.sample(samp, in.uv).rg;

        if (u.sharpen > 0.0) {
            float2 px = 1.0 / u.texSize;
            float b = yTex.sample(samp, in.uv + float2(0.0, -px.y)).r;
            float d = yTex.sample(samp, in.uv + float2(-px.x, 0.0)).r;
            float f = yTex.sample(samp, in.uv + float2( px.x, 0.0)).r;
            float h = yTex.sample(samp, in.uv + float2(0.0,  px.y)).r;
            Y = casSharpen(Y, b, d, f, h, u.sharpen);
        }

        if (u.fullRange == 0) {
            Y = (Y - 16.0/255.0) * (255.0/219.0);
            C = (C - 128.0/255.0) * (255.0/224.0);
        } else {
            C = C - 0.5;
        }
        Y = clamp(Y, 0.0, 1.0);

        float3 rgb;
        rgb.r = Y + 1.5748 * C.y;
        rgb.g = Y - 0.1873 * C.x - 0.4681 * C.y;
        rgb.b = Y + 1.8556 * C.x;
        rgb = clamp(rgb, 0.0, 1.0);

        if (u.contrast != 1.0) rgb = clamp((rgb - 0.5) * u.contrast + 0.5, 0.0, 1.0);
        if (u.saturation != 1.0) {
            float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            rgb = clamp(mix(float3(l), rgb, u.saturation), 0.0, 1.0);
        }
        if (u.gamma != 1.0) rgb = pow(rgb, float3(1.0 / u.gamma));

        return float4(rgb, 1.0);
    }
    """
}
