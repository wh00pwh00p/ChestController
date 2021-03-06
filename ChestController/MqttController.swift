//
//  MqttController.swift
//  ChestController
//
//  Created by Daniel on 31.10.16.
//  Copyright © 2016 Daniel. All rights reserved.
//

import Foundation
import CocoaMQTT

public class MqttController {
    let mqtt: CocoaMQTT
    let mission: Mission
    let missionBaseTopic: String
    
    init(mission: Mission) {
        self.mqtt = CocoaMQTT(clientId: "ChestController-\(arc4random_uniform(99999999))", host: "192.168.0.2", port: 1883)
        mqtt.connect()
        self.mission = mission
        self.missionBaseTopic = "missions/\(mission.id)/groups/1/participants/"
    }
    
    func publish(topic: String, message: String) {
        mqtt.publish(topic, withString: message)
    }
    
    /*
    log start and end of each scenario block
    */
    
    func logScenarioBlockStart(forBlock: ScenarioBlocks, withIdentifier: Int) {
        sendScenarioBlockLog(startEnd: "startScenarioBlock", forBlock: forBlock, withIdentifier: withIdentifier)
    }
    
    func logScenarioBlockEnd(forBlock: ScenarioBlocks, withIdentifier: Int) {
        sendScenarioBlockLog(startEnd: "endScenarioBlock", forBlock: forBlock, withIdentifier: withIdentifier)
    }
    
    private func sendScenarioBlockLog(startEnd: String, forBlock: ScenarioBlocks, withIdentifier: Int) {
        let timestamp = NSDate().timeIntervalSince1970
        let helperDict = ["event": startEnd, "description": "\(forBlock.rawValue)-\(String(withIdentifier))", "timestamp": String(timestamp)]
        let jsonMessage = try! JSONSerialization.data(withJSONObject: helperDict, options: JSONSerialization.WritingOptions.prettyPrinted)
        let stringMessage = NSString(data: jsonMessage, encoding: String.Encoding.ascii.rawValue)
        if let stringMessage = stringMessage {
            let stringWithoutLinebreaks = stringMessage.replacingOccurrences(of: "\n", with: "")
            mqtt.publish("logs", withString: stringWithoutLinebreaks)
        }
    }
    
    /*
    publish sensor values for one participant according to the event
    */
    func publishEvent(event: Event, forParticipant: String, baseValues:[Int]) -> [Int] {
        print("==============baseValues")
        print(baseValues)
        let newBaselineValues = generateNewBaseline(forEvent: event, withBaseValues: baseValues)
        print("==============newBaselineValues")
        print(newBaselineValues)
        let nextValues = generateNextValues(forValues: newBaselineValues)
        print("==============nextValues")
        print(nextValues)
        let topicAndMessage = generateMessages(forEvent: event, forParticipant: forParticipant, withValues: nextValues)
        for (topic, message) in topicAndMessage {
            mqtt.publish(topic, withString: message)
        }
        return nextValues
    }
    
    /* 
    creates a new baseline for every sensor that changes its values to another severity level
    */
    private func generateNewBaseline(forEvent: Event, withBaseValues: [Int]) -> [Int] {
        var newValues = withBaseValues
        switch forEvent {
        case .Critical(forSensor: let sensor, forParticipantNr: _):
            let currentValue = newValues[sensor.getIndex()]
            if !(currentValue >= sensor.getBoundaries()[2].0 && currentValue <= sensor.getBoundaries()[2].1) {
                newValues[sensor.getIndex()] = sensor.getCriticalBaseline()
            }
            break
        case .Warning(forSensor: let sensor, forParticipantNr: _):
            let currentValue = newValues[sensor.getIndex()]
            if !(currentValue >= sensor.getBoundaries()[1].0 && currentValue <= sensor.getBoundaries()[1].1) {
                newValues[sensor.getIndex()] = sensor.getWarningBaseline()
            }
            break
        case .NoConnection(forParticipantNr: _):
            newValues = [0, 0, 0, 0, 0, 0]
        case .CoreTempPeak(forParticipantNr: _):
            newValues[Sensors.CoreTemp.getIndex()] = 80
        case .Okay(forParticipantNr: _), .Retreated(forParticipantNr: _):
            let sensors = Sensors.getAll()
            for i in 0..<sensors.count {
                let currentValue = newValues[sensors[i].getIndex()]
                if !(currentValue >= sensors[i].getBoundaries()[0].0 && currentValue <= sensors[i].getBoundaries()[0].1) {
                    newValues[sensors[i].getIndex()] = sensors[i].getNormalBaseline()
                }
            }
            break
        default:
            break
        }
        return newValues
    }
    
    private func generateNextValues(forValues: [Int]) -> [Int] {
        let sensors = Sensors.getAll()
        var nextValues = forValues
        for sensor in sensors {
            var possibleChange = [Int]()
            let currentValue = forValues[sensor.getIndex()]
            //for conncetion lost values (0) and core temp peak (80), don't change the value
            if currentValue == 0 || (sensor.getIndex() == 1 && currentValue == 80) {
                possibleChange = [0]
            } else {
                var onLowerBoundary = false
                var onUpperBoundary = false
                let heartRateOrHumidity = sensor.getIndex() == 0 || sensor.getIndex() == 4
                for boundaries in sensor.getBoundaries() {
                    if currentValue == boundaries.0 {
                        onLowerBoundary = true
                        break
                    } else if currentValue == boundaries.1 {
                        onUpperBoundary = true
                        break
                    }
                    //for heart rate and humidity, also check one before the boundary
                    if heartRateOrHumidity {
                        if currentValue == boundaries.0 + 1 {
                            onLowerBoundary = true
                            break
                        } else if currentValue == boundaries.1 - 1 {
                            onUpperBoundary = true
                            break
                        }
                    }
                }
                if onUpperBoundary && onLowerBoundary {
                    possibleChange = [0]
                } else if onUpperBoundary {
                    possibleChange = [0,-1]
                    if heartRateOrHumidity {
                        possibleChange.append(-2)
                    }
                    
                } else if onLowerBoundary {
                    possibleChange = [0,1]
                    if heartRateOrHumidity {
                        possibleChange.append(2)
                    }
                } else {
                    possibleChange = [-1,0,1]
                    if heartRateOrHumidity {
                        possibleChange.append(2)
                        possibleChange.append(-2)
                    }
                }
            }
            let randomIndex = Int(arc4random_uniform(UInt32(possibleChange.count)))
            let increment = possibleChange[randomIndex]
            nextValues[sensor.getIndex()] = currentValue + increment
        }
        return nextValues
    }
    
    private func generateMessages(forEvent: Event, forParticipant: String, withValues: [Int]) -> [(String, String)] {
        let sensors = Sensors.getAll()
        var topicsAndMessages = [(String, String)]()
        let timestamp = NSDate().timeIntervalSince1970
        let userId = forParticipant
        for sensor in sensors {
            let sensorType = sensor.getBackendSensorType()
            let deviceType = "SecureDataCollector"
            let value = String(withValues[sensor.getIndex()])
            let helperDict = ["userId": userId, "missionId": self.mission.id, "sensorType": sensorType, "deviceType": deviceType, "timestamp": String(timestamp), "value": value]
            let jsonMessage = try! JSONSerialization.data(withJSONObject: helperDict, options: JSONSerialization.WritingOptions.prettyPrinted)
            let stringMessage = NSString(data: jsonMessage, encoding: String.Encoding.ascii.rawValue)
            if let stringMessage = stringMessage {
                let stringWithoutLinebreaks = stringMessage.replacingOccurrences(of: "\n", with: "")
                let stringWithoutWhitespace = stringWithoutLinebreaks.replacingOccurrences(of: " ", with: "")
                let topic = generateTopic(forParticipant: forParticipant, forSensor: sensor)
                topicsAndMessages.append((topic, stringWithoutWhitespace))
            } else {
                topicsAndMessages.append(("", ""))
            }
        }
        return topicsAndMessages
    }
    
    private func generateTopic(forParticipant: String, forSensor: Sensors) -> String {
        return missionBaseTopic + "\(forParticipant)/devices/values/SecureDataCollector/\(forSensor.getBackendSensorType())"
    }
}

extension MqttController: CocoaMQTTDelegate {
    
    public func mqtt(_ mqtt: CocoaMQTT, didConnect host: String, port: Int) {
        print("MQTT did connect")
    }
    
    public func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        print("MQTT did connect ack")
    }
    
    public func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        print("MQTT published message \(message.string) to topic \(message.topic)")
    }
    
    public func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        print("MQTT did publish Ack.")
    }
    
    public func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16 ) {
        print(message)
    }
    
    public func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopic topic: String) {
        NSLog("MQTT did subscribe to topic \(topic)")
    }
    
    public func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopic topic: String) {
        NSLog("MQTT did unsubscribe from topic \(topic)")
    }
    
    public func mqttDidPing(_ mqtt: CocoaMQTT) {
        NSLog("MQTT did ping")
    }
    
    public func mqttDidReceivePong(_ mqtt: CocoaMQTT) {
        NSLog("MQTT did receive pong")
    }
    
    public func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        print("MQTT did disconnect")
    }
    
}
