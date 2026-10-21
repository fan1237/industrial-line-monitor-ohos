// 传感器实时数据（一次采样）
export interface SensorData {
  temp: number    // 温度 °C
  humi: number    // 湿度 %
  sensor: boolean // 光电传感器是否触发
}
