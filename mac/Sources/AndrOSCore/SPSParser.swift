import Foundation

public enum SPSParser {

    /// Annex-B akisindan H.264 SPS (nal_unit_type 7) bulup renk bilgisini cikarir.
    public static func parseH264(_ stream: [UInt8]) -> ColorInfo? {
        for nal in NALU.split(stream) {
            guard let first = nal.first, (first & 0x1F) == 7 else { continue }
            var r = BitReader(NALU.rbsp(nal.dropFirst()))   // NAL basligini at
            var info = ColorInfo()

            let profileIdc = UInt8(r.u(8))
            r.skip(8)                                        // constraint flags + reserved
            let levelIdc = UInt8(r.u(8))
            info.profile = "H.264 profile_idc=\(profileIdc) level=\(Double(levelIdc)/10)"
            _ = r.ue()                                       // seq_parameter_set_id

            var chromaFormatIdc = 1
            if [100,110,122,244,44,83,86,118,128,138,139,134,135].contains(Int(profileIdc)) {
                chromaFormatIdc = Int(r.ue())
                if chromaFormatIdc == 3 { _ = r.flag() }      // separate_colour_plane_flag
                info.bitDepthLuma = Int(r.ue()) + 8           // bit_depth_luma_minus8
                _ = r.ue()                                    // bit_depth_chroma_minus8
                _ = r.flag()                                  // qpprime_y_zero_transform_bypass
                if r.flag() {                                 // seq_scaling_matrix_present
                    let n = chromaFormatIdc != 3 ? 8 : 12
                    for i in 0..<n where r.flag() {
                        skipScalingListH264(&r, size: i < 6 ? 16 : 64)
                    }
                }
            } else {
                info.bitDepthLuma = 8
            }
            info.chromaFormat = chromaFormatIdc

            _ = r.ue()                                        // log2_max_frame_num_minus4
            let pocType = r.ue()
            if pocType == 0 { _ = r.ue() }
            else if pocType == 1 {
                _ = r.flag(); _ = r.se(); _ = r.se()
                let n = r.ue()
                for _ in 0..<min(n, 256) { _ = r.se() }
            }
            _ = r.ue()                                        // max_num_ref_frames
            _ = r.flag()                                      // gaps_in_frame_num_allowed

            let widthMbs = Int(r.ue()) + 1
            let heightMapUnits = Int(r.ue()) + 1
            let frameMbsOnly = r.flag()
            if !frameMbsOnly { _ = r.flag() }                 // mb_adaptive_frame_field
            _ = r.flag()                                      // direct_8x8_inference

            var cropL = 0, cropR = 0, cropT = 0, cropB = 0
            if r.flag() {                                     // frame_cropping_flag
                cropL = Int(r.ue()); cropR = Int(r.ue())
                cropT = Int(r.ue()); cropB = Int(r.ue())
            }
            // Kirpma birimi chroma formatina bagli
            let subW = (chromaFormatIdc == 1 || chromaFormatIdc == 2) ? 2 : 1
            let subH = (chromaFormatIdc == 1) ? 2 : 1
            let cropUnitX = chromaFormatIdc == 0 ? 1 : subW
            let cropUnitY = (chromaFormatIdc == 0 ? 1 : subH) * (frameMbsOnly ? 1 : 2)
            info.width  = widthMbs * 16 - (cropL + cropR) * cropUnitX
            info.height = heightMapUnits * 16 * (frameMbsOnly ? 1 : 2) - (cropT + cropB) * cropUnitY

            if r.flag() { parseVUIColor(&r, into: &info) }     // vui_parameters_present_flag
            return info
        }
        return nil
    }

    /// Annex-B akisindan HEVC SPS (nal_unit_type 33) bulup renk bilgisini cikarir.
    public static func parseHEVC(_ stream: [UInt8]) -> ColorInfo? {
        for nal in NALU.split(stream) {
            guard nal.count > 2, let first = nal.first, ((first >> 1) & 0x3F) == 33 else { continue }
            var r = BitReader(NALU.rbsp(nal.dropFirst(2)))     // 2 baytlik NAL basligini at
            var info = ColorInfo()

            _ = r.u(4)                                          // sps_video_parameter_set_id
            let maxSubLayersMinus1 = Int(r.u(3))
            _ = r.flag()                                        // sps_temporal_id_nesting_flag
            let profileIdc = skipProfileTierLevel(&r, maxSubLayersMinus1: maxSubLayersMinus1)
            info.profile = "HEVC profile_idc=\(profileIdc)" + (profileIdc == 2 ? " (Main10)" : profileIdc == 1 ? " (Main)" : "")

            _ = r.ue()                                          // sps_seq_parameter_set_id
            let chromaFormatIdc = Int(r.ue())
            if chromaFormatIdc == 3 { _ = r.flag() }
            info.chromaFormat = chromaFormatIdc
            let picW = Int(r.ue()), picH = Int(r.ue())
            var cl = 0, cr = 0, ct = 0, cb = 0
            if r.flag() { cl = Int(r.ue()); cr = Int(r.ue()); ct = Int(r.ue()); cb = Int(r.ue()) }
            let subW = (chromaFormatIdc == 1 || chromaFormatIdc == 2) ? 2 : 1
            let subH = (chromaFormatIdc == 1) ? 2 : 1
            info.width  = picW - (cl + cr) * subW
            info.height = picH - (ct + cb) * subH

            info.bitDepthLuma = Int(r.ue()) + 8                 // bit_depth_luma_minus8
            _ = r.ue()                                          // bit_depth_chroma_minus8
            let log2MaxPocLsb = Int(r.ue()) + 4

            let subLayerOrderingInfo = r.flag()
            for _ in (subLayerOrderingInfo ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
                _ = r.ue(); _ = r.ue(); _ = r.ue()
            }
            _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue()

            if r.flag() {                                       // scaling_list_enabled_flag
                if r.flag() { skipScalingListHEVC(&r) }         // sps_scaling_list_data_present
            }
            _ = r.flag()                                        // amp_enabled_flag
            _ = r.flag()                                        // sample_adaptive_offset_enabled
            if r.flag() {                                       // pcm_enabled_flag
                _ = r.u(4); _ = r.u(4); _ = r.ue(); _ = r.ue(); _ = r.flag()
            }

            let numShortTermRps = Int(r.ue())
            var numDeltaPocs = [Int](repeating: 0, count: max(numShortTermRps + 1, 1))
            for i in 0..<min(numShortTermRps, 64) {
                numDeltaPocs[i] = parseShortTermRPS(&r, idx: i, numDeltaPocs: numDeltaPocs)
            }
            if r.flag() {                                       // long_term_ref_pics_present_flag
                let n = Int(r.ue())
                for _ in 0..<min(n, 64) { _ = r.u(log2MaxPocLsb); _ = r.flag() }
            }
            _ = r.flag()                                        // sps_temporal_mvp_enabled
            _ = r.flag()                                        // strong_intra_smoothing_enabled

            if r.flag() { parseVUIColor(&r, into: &info) }       // vui_parameters_present_flag
            return info
        }
        return nil
    }

    // MARK: - Ortak VUI renk bolumu (H.264 ve HEVC'de ayni yapida)

    private static func parseVUIColor(_ r: inout BitReader, into info: inout ColorInfo) {
        if r.flag() {                                    // aspect_ratio_info_present_flag
            let idc = r.u(8)
            if idc == 255 { _ = r.u(16); _ = r.u(16) }    // Extended_SAR
        }
        if r.flag() { _ = r.flag() }                     // overscan_info / overscan_appropriate
        if r.flag() {                                    // video_signal_type_present_flag
            _ = r.u(3)                                   // video_format
            info.fullRange = r.flag()                    // video_full_range_flag
            if r.flag() {                                // colour_description_present_flag
                info.primaries = UInt8(r.u(8))
                info.transfer  = UInt8(r.u(8))
                info.matrix    = UInt8(r.u(8))
            }
        }
    }

    // MARK: - Atlama yardimcilari

    private static func skipScalingListH264(_ r: inout BitReader, size: Int) {
        var lastScale = 8, nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                let delta = r.se()
                nextScale = (lastScale + Int(delta) + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
    }

    private static func skipScalingListHEVC(_ r: inout BitReader) {
        for sizeId in 0..<4 {
            var matrixId = 0
            while matrixId < 6 {
                if !r.flag() { _ = r.ue() }              // pred_mode / pred_matrix_id_delta
                else {
                    let coefNum = min(64, 1 << (4 + (sizeId << 1)))
                    if sizeId > 1 { _ = r.se() }         // scaling_list_dc_coef_minus8
                    for _ in 0..<coefNum { _ = r.se() }
                }
                matrixId += (sizeId == 3) ? 3 : 1
            }
        }
    }

    /// st_ref_pic_set() — bu kumenin NumDeltaPocs degerini doner.
    private static func parseShortTermRPS(_ r: inout BitReader, idx: Int, numDeltaPocs: [Int]) -> Int {
        var interPred = false
        if idx != 0 { interPred = r.flag() }
        if interPred {
            _ = r.flag()                                  // delta_rps_sign
            _ = r.ue()                                    // abs_delta_rps_minus1
            let refCount = numDeltaPocs[max(idx - 1, 0)]
            var kept = 0
            for _ in 0...refCount {                       // j = 0..NumDeltaPocs[RefRpsIdx] DAHIL
                let usedByCurr = r.flag()
                let useDelta = usedByCurr ? true : r.flag()
                if useDelta { kept += 1 }
            }
            return kept
        } else {
            let neg = Int(r.ue()), pos = Int(r.ue())
            for _ in 0..<min(neg, 64) { _ = r.ue(); _ = r.flag() }
            for _ in 0..<min(pos, 64) { _ = r.ue(); _ = r.flag() }
            return neg + pos
        }
    }

    /// profile_tier_level() — general_profile_idc doner.
    private static func skipProfileTierLevel(_ r: inout BitReader, maxSubLayersMinus1: Int) -> Int {
        _ = r.u(2)                                        // general_profile_space
        _ = r.flag()                                      // general_tier_flag
        let profileIdc = Int(r.u(5))
        r.skip(32)                                        // profile_compatibility_flags
        r.skip(48)                                        // constraint/reserved bitleri
        _ = r.u(8)                                        // general_level_idc

        var subProfile = [Bool](), subLevel = [Bool]()
        for _ in 0..<maxSubLayersMinus1 { subProfile.append(r.flag()); subLevel.append(r.flag()) }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { _ = r.u(2) }  // reserved_zero_2bits
        }
        for i in 0..<maxSubLayersMinus1 {
            if subProfile[i] { r.skip(88) }
            if subLevel[i]   { _ = r.u(8) }
        }
        return profileIdc
    }
}
