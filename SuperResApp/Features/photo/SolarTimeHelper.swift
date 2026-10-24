import Foundation
import CoreLocation

struct SolarTimeHelper {
    /// 根据时间和位置，计算出当前的太阳事件概率分布
    /// 返回 6 个概率：[黎明, 日出, 正午, 日落, 黄昏, 午夜]
    static func getSunEventWeights(date: Date, location: CLLocation?) -> [CGFloat] {
        // 如果没有位置信息，回退到简单的时钟估算
        guard let location = location else {
            let hour = CGFloat(Calendar.current.component(.hour, from: date))
            return estimateByClock(hour: hour)
        }
        
        // 简化的天文计算（基于纬度的白昼长度估算）
        let calendar = Calendar.current
        let hour = CGFloat(calendar.component(.hour, from: date)) + CGFloat(calendar.component(.minute, from: date)) / 60.0
        
        let lat = CGFloat(location.coordinate.latitude)
        let dayLength = 12.0 + (lat / 90.0) * 4.0 
        let sunrise = 12.0 - dayLength / 2.0
        let sunset = 12.0 + dayLength / 2.0
        
        return calculateWeights(hour: hour, sunrise: sunrise, sunset: sunset)
    }
    
    private static func estimateByClock(hour: CGFloat) -> [CGFloat] {
        return calculateWeights(hour: hour, sunrise: 6.0, sunset: 18.0)
    }
    
    private static func calculateWeights(hour: CGFloat, sunrise: CGFloat, sunset: CGFloat) -> [CGFloat] {
        func gauss(center: CGFloat, sigma: CGFloat) -> CGFloat {
            let d = (hour - center) / sigma
            return exp(-0.5 * d * d)
        }
        
        let dawn     = gauss(center: sunrise - 1.0, sigma: 1.2)
        let sunEvent = gauss(center: sunrise, sigma: 0.8)
        let noon     = gauss(center: 12.0, sigma: 2.0)
        let sunsetEv = gauss(center: sunset, sigma: 0.8)
        let dusk     = gauss(center: sunset + 1.0, sigma: 1.2)
        let midnight = gauss(center: 0.0, sigma: 3.0) + gauss(center: 24.0, sigma: 3.0)
        
        return [dawn, sunEvent, noon, sunsetEv, dusk, midnight]
    }
}