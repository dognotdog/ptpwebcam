//
//  CameraAgentTests.swift
//  CameraAgentTests
//

import XCTest
import AppKit
@testable import PtpCameraAgent

final class CameraAgentTests: XCTestCase {

    // MARK: - formatExtPropRaw

    func testApertureFormatNikon() {
        // 450 = f/4.5 (encoded as f×100)
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 450), propId: 0x5007, vendor: .nikon), "f/4.5")
    }

    func testApertureFormatSony() {
        // Sony also uses f×100 encoding (same formula)
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 450), propId: 0xD1A9, vendor: .sony), "f/4.5")
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 180), propId: 0xD1A9, vendor: .sony), "f/1.8")
    }

    func testApertureWholeNumber() {
        // 800 = f/8.0 → should display as "f/8.0"
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 800), propId: 0x5007), "f/8.0")
    }

    func testShutterSpeedFraction() {
        // nom=10, den=500 → "1/50"
        let val = UInt32((10 << 16) | 500)
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: val), propId: 0xD100), "1/50")
    }

    func testShutterSpeedBulb() {
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: UInt32(0xFFFFFFFF)), propId: 0xD100), "Bulb")
    }

    func testShutterSpeedFlash() {
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: UInt32(0xFFFFFFFE)), propId: 0xD100), "Flash")
    }

    func testShutterSpeedSeconds() {
        // nom=30, den=10 → "3\""  (3 seconds: 0.1 × 30)
        let val = UInt32((30 << 16) | 10)
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: val), propId: 0xD100), "3\"")
    }

    func testWbNameLookup() {
        // 0x8011 = Shade
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: UInt32(0x8011)), propId: 0x5005), "Shade")
        // 0x0006 = Tungsten
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: UInt32(0x0006)), propId: 0x5005), "Tungsten")
        // 0x0004 = Daylight
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: UInt32(0x0004)), propId: 0x5005), "Daylight")
    }

    func testExposureBiasPositive() {
        // 1000 → "+1.0 EV"
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 1000), propId: 0x5010), "+1.0 EV")
    }

    func testExposureBiasNegative() {
        // -1000 as Int32 bit pattern → "-1.0 EV"
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: -1000), propId: 0x5010), "-1.0 EV")
    }

    func testBatteryLevel() {
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 75), propId: 0x5001), "75%")
    }

    func testSonyBatteryLevel() {
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 75), propId: 0xD218), "75%")
    }

    func testSonyBatteryExternalPower() {
        // Sony reports -1 (Int8 0xFF) when running on external power.
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: -1), propId: 0xD218), "External")
    }

    func testNikonWbTunePositive() {
        // Camera reports raw 9, neutral=6, so display +3
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 9), propId: 0xD018), "+3")
    }

    func testNikonWbTuneNeutral() {
        // Raw 6 == neutral, displayed as "+0"
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 6), propId: 0xD018), "+0")
    }

    func testNikonWbTuneNegative() {
        // Raw 4, neutral=6, so display -2
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 4), propId: 0xD018), "-2")
    }

    func testNikonWbTuneExtremes() {
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 0),  propId: 0xD017), "-6")
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 12), propId: 0xD017), "+6")
    }

    func testSonyWbTune() {
        // Sony WB tune: neutral at 128
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 128), propId: 0xD210), "+0")
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 131), propId: 0xD210), "+3")
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 125), propId: 0xD210), "-3")
    }

    func testColorTempKelvin() {
        XCTAssertEqual(formatExtPropRaw(NSNumber(value: 5500), propId: 0xD01E), "5500 K")
    }

    // MARK: - CameraVendor detection

    func testVendorNikon() {
        XCTAssertEqual(vendorFrom(vid: 0x04B0), .nikon)
    }

    func testVendorSony() {
        XCTAssertEqual(vendorFrom(vid: 0x054C), .sony)
    }

    func testVendorCanon() {
        XCTAssertEqual(vendorFrom(vid: 0x04A9), .canon)
    }

    func testVendorUnknown() {
        XCTAssertEqual(vendorFrom(vid: 0x0000), .unknown)
        XCTAssertEqual(vendorFrom(vid: 0xFFFF), .unknown)
    }

    // MARK: - SliderActionHolder debounce

    func testSliderOnDisplayCalledImmediately() {
        var displayValues: [Double] = []
        var commandValues: [Double] = []

        let holder = SliderActionHolder(propId: 0x500F, rangeMin: 0, rangeStep: 1) { val in
            commandValues.append(val)
        }
        holder.onDisplay = { val in displayValues.append(val) }

        let slider = NSSlider()
        slider.minValue = 0; slider.maxValue = 3200

        // Simulate rapid drag events
        slider.doubleValue = 100; holder.sliderChanged(slider)
        slider.doubleValue = 200; holder.sliderChanged(slider)
        slider.doubleValue = 400; holder.sliderChanged(slider)

        // onDisplay must be called synchronously for each event
        XCTAssertEqual(displayValues, [100, 200, 400])
        // onCommand must NOT have fired yet (debounce pending)
        XCTAssertEqual(commandValues, [])
    }

    func testSliderDebounceFiresOnce() {
        var commandValues: [Double] = []
        let exp = expectation(description: "debounce fires")

        let holder = SliderActionHolder(propId: 0x500F, rangeMin: 0, rangeStep: 1) { val in
            commandValues.append(val)
            exp.fulfill()
        }

        let slider = NSSlider()
        slider.minValue = 0; slider.maxValue = 3200

        // Send three rapid events — only the last value should be commanded
        slider.doubleValue = 100; holder.sliderChanged(slider)
        slider.doubleValue = 200; holder.sliderChanged(slider)
        slider.doubleValue = 800; holder.sliderChanged(slider)

        // Wait for debounce (150 ms) + margin
        waitForExpectations(timeout: 1.0)

        XCTAssertEqual(commandValues.count, 1, "onCommand should fire exactly once")
        XCTAssertEqual(commandValues.first, 800, "should command the last value")
    }

    func testSliderSnapsToStep() {
        var displayValues: [Double] = []
        let holder = SliderActionHolder(propId: 0x5007, rangeMin: 0, rangeStep: 100) { _ in }
        holder.onDisplay = { val in displayValues.append(val) }

        let slider = NSSlider()
        slider.minValue = 0; slider.maxValue = 2000
        slider.doubleValue = 150   // between steps 100 and 200 → snaps to 100
        holder.sliderChanged(slider)

        XCTAssertEqual(displayValues.first, 100)
    }
}

// MARK: - Helpers

private func vendorFrom(vid: UInt16) -> CameraVendor {
    switch vid {
    case 0x04B0: return .nikon
    case 0x054C: return .sony
    case 0x04A9: return .canon
    default:     return .unknown
    }
}
