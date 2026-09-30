import CoreGraphics
import XCTest
@testable import Paperbound

final class PageContentGeometryTests: XCTestCase {
    func testEnchantedRasterFitsAlignedBudgetAcrossDuoShapes() {
        // 776 x 1096 previously passed the area cap but failed GPU admission.
        XCTAssertFalse(InkTextureLayout(width: 776, height: 1096).fitsSpread)
        for width in stride(from: 240, through: 950, by: 13) {
            for height in stride(from: 300, through: 950, by: 17) {
                let display = CGSize(width: width, height: height)
                let minimum = PageRenderScale.bucketedPixelSize(display)
                guard InkTextureLayout(width: Int(minimum.width), height: Int(minimum.height)).fitsSpread else { continue }
                let pixels = PageRenderScale.pixelSize(for: display, displayScale: 3, enchanted: true)
                XCTAssertEqual(pixels, PageRenderScale.bucketedPixelSize(pixels))
                XCTAssertTrue(InkTextureLayout(width: Int(pixels.width), height: Int(pixels.height)).fitsSpread,
                              "Oversized prepared raster: \(pixels)")
                XCTAssertGreaterThanOrEqual(pixels.width, minimum.width)
                XCTAssertGreaterThanOrEqual(pixels.height, minimum.height)
            }
        }
    }

    func testCameraOcclusionMovesContentIntoLargestClearRectangle() {
        let page = CGRect(x: 0, y: 0, width: 600, height: 800)
        let camera = CGRect(x: 250, y: 0, width: 100, height: 40)

        let fraction = PageContentGeometry.readableFraction(
            for: page,
            within: page,
            excluding: [camera]
        )
        let contentRect = CGRect(
            x: page.minX + fraction.minX * page.width,
            y: page.minY + fraction.minY * page.height,
            width: fraction.width * page.width,
            height: fraction.height * page.height
        )

        let cameraOverlap = contentRect.intersection(camera)
        XCTAssertTrue(cameraOverlap.isNull || cameraOverlap.isEmpty)
        XCTAssertEqual(contentRect.minY, camera.maxY, accuracy: 0.001)
        XCTAssertEqual(contentRect.width, page.width, accuracy: 0.001)
    }

    func testContentBoundsRespectSafeAreaAndMultipleOcclusions() {
        let page = CGRect(x: 0, y: 0, width: 600, height: 800)
        let safe = CGRect(x: 0, y: 30, width: 600, height: 740)
        let camera = CGRect(x: 250, y: 30, width: 100, height: 40)
        let sideOcclusion = CGRect(x: 0, y: 450, width: 50, height: 100)

        let fraction = PageContentGeometry.readableFraction(
            for: page,
            within: safe,
            excluding: [camera, sideOcclusion]
        )
        let contentRect = CGRect(
            x: page.minX + fraction.minX * page.width,
            y: page.minY + fraction.minY * page.height,
            width: fraction.width * page.width,
            height: fraction.height * page.height
        )

        XCTAssertGreaterThanOrEqual(contentRect.minY, safe.minY)
        XCTAssertLessThanOrEqual(contentRect.maxY, safe.maxY)
        XCTAssertTrue(contentRect.intersection(camera).isNull || contentRect.intersection(camera).isEmpty)
        XCTAssertTrue(contentRect.intersection(sideOcclusion).isNull || contentRect.intersection(sideOcclusion).isEmpty)
    }
}
