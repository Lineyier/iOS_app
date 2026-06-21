import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = HealthViewModel()
    @State private var showJSONPreview = false

    var body: some View {
        NavigationView {
            Form {
                Section("HealthKit") {
                    HStack {
                        Text("Доступ:")
                        Spacer()
                        Text(viewModel.isAuthorized ? "разрешён" : "нет")
                            .foregroundColor(viewModel.isAuthorized ? .green : .red)
                    }

                    Button("Запросить доступ к HealthKit") {
                        viewModel.requestAuthorization()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section("Данные за сегодня") {
                    if viewModel.isLoading {
                        HStack {
                            ProgressView()
                            Text("Загрузка…")
                        }
                    }

                    LabeledContent("Шаги", value: "\(Int(viewModel.stepsToday))")
                    LabeledContent("Активные калории", value: String(format: "%.0f kcal", viewModel.activeEnergyBurnedKcalToday))
                    LabeledContent("Дистанция (ходьба/бег)", value: String(format: "%.2f km", viewModel.distanceWalkingRunningKmToday))
                    LabeledContent("Exercise", value: String(format: "%.0f min", viewModel.exerciseMinutesToday))
                    LabeledContent("Stand (часы)", value: "\(viewModel.standHoursToday)")

                    if let hr = viewModel.heartRateLatestBpm {
                        LabeledContent("Пульс (последний)", value: String(format: "%.0f bpm", hr))
                    } else {
                        LabeledContent("Пульс (последний)", value: "нет данных")
                    }

                    Button(viewModel.isLoading ? "Загрузка…" : "Обновить данные") {
                        viewModel.loadTodaySummary()
                    }
                    .disabled(!viewModel.isAuthorized || viewModel.isLoading)
                }

                Section("Тренировки (сегодня)") {
                    if viewModel.workoutsToday.isEmpty {
                        Text("Тренировок не найдено.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.workoutsToday) { w in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(w.activityType)
                                    .font(.headline)

                                Text("\(w.start.formatted(date: .abbreviated, time: .shortened)) → \(w.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                HStack {
                                    Text(String(format: "duration: %.0f min", w.durationSec / 60.0))
                                    Spacer()
                                    if let kcal = w.totalEnergyBurnedKcal {
                                        Text(String(format: "%.0f kcal", kcal))
                                    }
                                    if let km = w.totalDistanceKm {
                                        Text(String(format: "%.2f km", km))
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Отправка JSON на десктоп") {
                    Picker("Транспорт", selection: $viewModel.transport) {
                        ForEach(HealthViewModel.SendTransport.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    if viewModel.transport == .webSocket {
                        TextField("WebSocket URL", text: $viewModel.webSocketEndpoint)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                        HStack {
                            Button("Connect") { viewModel.connectWebSocket() }
                                .buttonStyle(.bordered)
                            Button("Disconnect") { viewModel.disconnectWebSocket() }
                                .buttonStyle(.bordered)
                        }
                        LabeledContent("Статус", value: viewModel.connectionStatus)
                    } else {
                        TextField("HTTP(S) endpoint", text: $viewModel.httpEndpoint)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                        LabeledContent("Статус", value: viewModel.connectionStatus)
                    }

                    Button("Отправить JSON") {
                        viewModel.sendHealthData()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.isAuthorized)

                    Button("Показать JSON (preview)") {
                        showJSONPreview = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isAuthorized)
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Health Companion")
            .sheet(isPresented: $showJSONPreview) {
                JSONPreviewView(json: viewModel.buildJSONPreview())
            }
        }
    }
}

private struct JSONPreviewView: View {
    let json: String

    var body: some View {
        NavigationView {
            ScrollView {
                Text(json.isEmpty ? "{}" : json)
                    .font(.system(.footnote, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("JSON preview")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
}
