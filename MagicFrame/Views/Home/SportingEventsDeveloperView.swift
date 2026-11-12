import SwiftUI

/// Developer tools scoped to Sporting Events (stadium catalog editing).
struct SportingEventsDeveloperView: View {

    @ObservedObject var vm: LibraryViewModel

    @State private var stadiums: [Stadium] = []
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                Text("Sporting Events")
                    .font(.title2.weight(.bold))
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section("Stadiums catalog") {
                NavigationLink {
                    StadiumEditorView(stadiumId: nil, onSaved: reload)
                } label: {
                    Label("Add Stadium", systemImage: "plus.circle")
                }

                if stadiums.isEmpty {
                    Text("No stadiums yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stadiums) { stadium in
                        NavigationLink {
                            StadiumEditorView(stadiumId: stadium.stadiumId, onSaved: reload)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stadium.name)
                                HStack(spacing: 8) {
                                    if let cityState = stadium.cityStateLine {
                                        Text(cityState)
                                    }
                                    Text("\(stadium.aliases.count) aliases")
                                    Text("\(stadium.teams.count) teams")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteStadiums)
                }

                Text("Edit stadiums, aliases, and home teams used for game lookup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Full developer console") {
                NavigationLink("All Developer Tools") {
                    DeveloperView(vm: vm)
                }
            }
        }
        .navigationTitle("Sporting Events")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() {
        stadiums = AppDependencies.database.fetchAllStadiums()
        statusMessage = "\(stadiums.count) stadium\(stadiums.count == 1 ? "" : "s")"
    }

    private func deleteStadiums(at offsets: IndexSet) {
        for index in offsets {
            let stadium = stadiums[index]
            AppDependencies.database.deleteStadium(stadiumId: stadium.stadiumId)
        }
        reload()
    }
}

private struct StadiumEditorView: View {

    let stadiumId: Int?
    let onSaved: () -> Void

    @State private var name = ""
    @State private var city = ""
    @State private var state = ""
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var aliases: [String] = []
    @State private var teams: [StadiumTeam] = []
    @State private var newAlias = ""
    @State private var editingTeam: StadiumTeamDraft?
    @State private var statusMessage: String?
    @State private var resolvedStadiumId: Int?

    private var isEditingExisting: Bool {
        (resolvedStadiumId ?? stadiumId) != nil
    }

    var body: some View {
        Form {
            Section("Stadium") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("City", text: $city)
                    .textInputAutocapitalization(.words)
                TextField("State", text: $state)
                    .textInputAutocapitalization(.characters)
                TextField("Latitude", text: $latitudeText)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitudeText)
                    .keyboardType(.numbersAndPunctuation)
            }

            if let resolvedStadiumId {
                Section("Aliases") {
                    ForEach(aliases, id: \.self) { alias in
                        Text(alias)
                    }
                    .onDelete(perform: deleteAliases)

                    HStack {
                        TextField("Add alias", text: $newAlias)
                            .textInputAutocapitalization(.words)
                        Button("Add") {
                            addAlias(stadiumId: resolvedStadiumId)
                        }
                        .disabled(newAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Home teams") {
                    ForEach(teams) { team in
                        Button {
                            editingTeam = StadiumTeamDraft(team: team)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(team.uiName)
                                    .foregroundStyle(.primary)
                                Text(
                                    "\(team.league.displayName) · \(team.teamName)"
                                        + (team.isPrimaryHome ? " · primary" : "")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteTeams)

                    Button("Add Team") {
                        editingTeam = StadiumTeamDraft(stadiumId: resolvedStadiumId)
                    }
                }
            } else {
                Section {
                    Text("Save the stadium first, then add aliases and teams.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(isEditingExisting ? "Edit Stadium" : "Add Stadium")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveStadium() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear(perform: load)
        .sheet(item: $editingTeam) { draft in
            NavigationStack {
                StadiumTeamEditorView(draft: draft) { saved in
                    persistTeam(saved)
                }
            }
        }
    }

    private func load() {
        guard let stadiumId,
              let stadium = AppDependencies.database.fetchStadium(stadiumId: stadiumId) else {
            resolvedStadiumId = nil
            return
        }
        resolvedStadiumId = stadium.stadiumId
        name = stadium.name
        city = stadium.city ?? ""
        state = stadium.state ?? ""
        latitudeText = stadium.latitude.map { String($0) } ?? ""
        longitudeText = stadium.longitude.map { String($0) } ?? ""
        aliases = stadium.aliases
        teams = stadium.teams
    }

    private func reloadDetails(stadiumId: Int) {
        guard let stadium = AppDependencies.database.fetchStadium(stadiumId: stadiumId) else { return }
        resolvedStadiumId = stadium.stadiumId
        aliases = stadium.aliases
        teams = stadium.teams
        onSaved()
    }

    private func saveStadium() {
        let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        let savedId = AppDependencies.database.upsertStadium(
            stadiumId: resolvedStadiumId ?? stadiumId,
            name: name,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude
        )
        guard let savedId else {
            statusMessage = "Could not save stadium. Check for a duplicate name."
            return
        }
        resolvedStadiumId = savedId
        statusMessage = "Saved stadium."
        reloadDetails(stadiumId: savedId)
    }

    private func addAlias(stadiumId: Int) {
        let trimmed = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppDependencies.database.addStadiumAlias(stadiumId: stadiumId, alias: trimmed)
        newAlias = ""
        reloadDetails(stadiumId: stadiumId)
    }

    private func deleteAliases(at offsets: IndexSet) {
        guard let stadiumId = resolvedStadiumId else { return }
        for index in offsets {
            AppDependencies.database.deleteStadiumAlias(
                stadiumId: stadiumId,
                alias: aliases[index]
            )
        }
        reloadDetails(stadiumId: stadiumId)
    }

    private func deleteTeams(at offsets: IndexSet) {
        guard let stadiumId = resolvedStadiumId else { return }
        for index in offsets {
            if let teamId = teams[index].stadiumTeamId {
                AppDependencies.database.deleteStadiumTeam(stadiumTeamId: teamId)
            }
        }
        reloadDetails(stadiumId: stadiumId)
    }

    private func persistTeam(_ draft: StadiumTeamDraft) {
        guard let stadiumId = resolvedStadiumId ?? draft.stadiumId else { return }
        let saved = AppDependencies.database.upsertStadiumTeam(
            stadiumTeamId: draft.stadiumTeamId,
            stadiumId: stadiumId,
            league: draft.league,
            teamName: draft.teamName,
            displayName: draft.displayName,
            teamAbbreviation: draft.teamAbbreviation,
            isPrimaryHome: draft.isPrimaryHome
        )
        statusMessage = saved == nil ? "Could not save team." : "Saved team."
        reloadDetails(stadiumId: stadiumId)
    }
}

private struct StadiumTeamDraft: Identifiable, Equatable {
    let id: UUID
    var stadiumTeamId: Int?
    var stadiumId: Int?
    var league: SportsLeague
    var teamName: String
    var displayName: String
    var teamAbbreviation: String
    var isPrimaryHome: Bool

    init(stadiumId: Int) {
        id = UUID()
        stadiumTeamId = nil
        self.stadiumId = stadiumId
        league = .collegeFootball
        teamName = ""
        displayName = ""
        teamAbbreviation = ""
        isPrimaryHome = true
    }

    init(team: StadiumTeam) {
        id = UUID()
        stadiumTeamId = team.stadiumTeamId
        stadiumId = team.stadiumId
        league = team.league
        teamName = team.teamName
        displayName = team.displayName ?? ""
        teamAbbreviation = team.teamAbbreviation ?? ""
        isPrimaryHome = team.isPrimaryHome
    }
}

private struct StadiumTeamEditorView: View {

    @State private var draft: StadiumTeamDraft
    let onSave: (StadiumTeamDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    init(draft: StadiumTeamDraft, onSave: @escaping (StadiumTeamDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Team") {
                Picker("League", selection: $draft.league) {
                    ForEach(SportsLeague.allCases) { league in
                        Text(league.displayName).tag(league)
                    }
                }
                TextField("Team name (match)", text: $draft.teamName)
                    .textInputAutocapitalization(.words)
                TextField("Display name", text: $draft.displayName)
                    .textInputAutocapitalization(.words)
                TextField("Abbreviation", text: $draft.teamAbbreviation)
                    .textInputAutocapitalization(.characters)
                Toggle("Primary home team", isOn: $draft.isPrimaryHome)
            }

            Section {
                Text("Team name is used for ESPN matching (e.g. Georgia Tech). Display name is for UI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(draft.stadiumTeamId == nil ? "Add Team" : "Edit Team")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(draft.teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
