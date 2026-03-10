//
//  janus_testApp.swift
//  janus-test
//
//  Created by jameel on 02/03/26.
//

import SwiftUI

@main
struct janus_testApp: App {
    var body: some Scene {
        WindowGroup {
//            ContentView()
//            RootNavigationView()
            TestView()
        }
    }
}


struct TestView: View {
    let star = StarScreamClient()
    
    var body: some View {
        ZStack {
            Text("Hello, World!")
        }
            .onAppear{
                star.connect()
            }
    }
}
