//
//  AboutDetailView.swift
//  VM4A
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI

#if arch(arm64)
struct AboutDetailHomeView: View {
    var body: some View {
        VMWebView(url: URL(string:"https://vm4a.app")!)
            .navigationTitle("About - VM4A")
    }
}

struct AboutDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        AboutDetailHomeView()
    }
}

#endif
