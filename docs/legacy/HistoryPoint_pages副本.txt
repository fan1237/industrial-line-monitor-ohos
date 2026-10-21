// 落库的历史数据点：比 SensorData 多一个时间戳，用于按时间范围查询与回看
export interface HistoryPoint {
  ts: number       // 采集时间戳（毫秒）
  temp: number     // 温度 °C
  humi: number     // 湿度 %
  sensor: boolean  // 光电传感器是否触发
}
