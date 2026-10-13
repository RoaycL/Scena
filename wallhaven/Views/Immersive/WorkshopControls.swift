//
//  WorkshopControls.swift
//  wallhaven
//

import SwiftUI

/// 创意工坊在线浏览的筛选面板
struct WorkshopFilterPanel: View {
    @EnvironmentObject private var workshop: WorkshopViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("类型").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("类型", selection: $workshop.typeFilter) {
                    ForEach(WorkshopTypeFilter.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("排序").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("排序", selection: $workshop.sort) {
                    ForEach(WorkshopSort.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            Toggle("显示「Questionable」分级", isOn: $workshop.includeQuestionable)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Text("「应用」类型（Windows 程序）和 Mature 分级不会显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// 已下载 / 在线 切换
struct WorkshopModePicker: View {
    @EnvironmentObject private var workshop: WorkshopViewModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkshopViewModel.Mode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { workshop.mode = mode }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(workshop.mode == mode ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(workshop.mode == mode ? .white.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
