//
//  IssuesDetailView.swift
//  VM4A
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI

#if arch(arm64)
struct IssuesDetailHomeView: View {
    var body: some View {
        VMWebView(url: URL(string:"https://github.com/everettjf/vm4a/issues")!)
            .navigationTitle("Issues - VM4A")
    }
}

struct IssuesDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        IssuesDetailHomeView()
    }
}

#endif
