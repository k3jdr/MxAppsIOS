//
//  TargetAccountLinks.swift
//  MxAcctMGR
//
//  Links on target accounts (Banking): a web page, an email address or a page in MxNoteONE on a target account,
//  with words of its own and formatted hover text — made and shown as links on securities are (Shared/Links): the
//  Link dialog (Text to display, Address, Hover text) and the hover card. Kept in the security master
//  (srm.payee_link, V032) through the accounts service, a link belongs to the target account: it shows wherever the
//  account is a target — the Checking Accounts register's Target column, the card registers', Target Accounts — and
//  a change made in one shows in the others.
//

import Observation
import SwiftUI

/// A target account's link as the accounts service sends it (the hover text as RTF).
struct TargetLink: Decodable, Hashable {
    var address: String
    var text: String?
    var tip: String?
    var title: String?

    var link: SecurityLink { SecurityLink(address: address, text: text, tip: tip.map { Data($0.utf8) }, title: title) }
}

/// The target account the Link dialog is open for.
struct PayeeLinkTarget: Identifiable {
    var payeeId: Int
    var name: String
    var last4: String?
    var institution: String?
    /// Its logon page, offered to link to.
    var website: String?
    var link: SecurityLink?
    var id: Int { payeeId }

    init(_ p: Payee) {
        payeeId = p.id; name = p.name; last4 = p.last4; institution = p.institution; website = p.logonUrl; link = p.link?.link
    }

    /// A register entry's target, when it has one (the logon page comes from Target Accounts).
    init?(_ e: RegisterEntry, website: String? = nil) {
        guard let id = e.payeeId else { return nil }
        payeeId = id; name = e.payee ?? ""; last4 = e.payeeLast4; institution = e.payeeInstitution
        self.website = website; link = e.payeeLink?.link
    }

    /// The bank or company and the last four digits, as the dialog shows them.
    var detail: String? {
        let parts = [institution, last4.map { "account ending \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The target account's logon page, to link to.
    var pages: [SecurityPage] {
        guard let w = website?.trimmingCharacters(in: .whitespaces), !w.isEmpty, let url = LinkRichText.url(fromAddress: w) else { return [] }
        return [SecurityPage(title: "\(name) — its logon page", address: url.absoluteString)]
    }
}

@MainActor
@Observable
final class PayeeLinks {
    static let shared = PayeeLinks()

    /// The Link dialog is open for this target account.
    var editing: PayeeLinkTarget?
    /// Bumped when a link is saved or taken off: the Banking screens load again, so each shows it.
    private(set) var version = 0

    /// Opens the Link dialog (the target cell's link button, a row's context menu, Edit Link… on a hover card).
    func beginEdit(_ t: PayeeLinkTarget?) {
        guard let t else { return NSSound.beep() }
        LinkHover.shared.close()
        editing = t
    }

    /// Saves (or with nil takes off) the target account's link; answers why it couldn't, or nil.
    func save(_ link: SecurityLink?, for t: PayeeLinkTarget) async -> String? {
        do {
            try await BankClient.savePayeeLink(t.payeeId, link)
            version += 1
            return nil
        } catch {
            return describe(error)
        }
    }

    /// The linked words of a target: a click opens the link, the hover card edits or removes it.
    func words(_ t: PayeeLinkTarget, link: SecurityLink, struck: Bool = false, testID: String) -> LinkedWords {
        LinkedWords(link: link, words: t.name, struck: struck, testID: testID,
                    edit: { PayeeLinks.shared.beginEdit(t) },
                    remove: { Task { _ = await PayeeLinks.shared.save(nil, for: t) } })
    }
}

/// The Link dialog for a target account.
struct PayeeLinkSheet: View {
    let target: PayeeLinkTarget

    var body: some View {
        LinkSheet(subject: target.name, detail: target.detail, initial: target.link, words: target.name, pages: target.pages,
                  whereKept: "Kept in the security master with the target account: it shows wherever \(target.name) is a target — the Checking and card registers, and Target Accounts.") { link in
            await PayeeLinks.shared.save(link, for: target)
        }
    }
}

/// A target's context-menu items: add or edit its link, and open it.
@ViewBuilder
func payeeLinkMenu(_ t: PayeeLinkTarget?) -> some View {
    if let t {
        Button(t.link == nil ? "Add Link to \(t.name)…" : "Edit Link on \(t.name)…") { PayeeLinks.shared.beginEdit(t) }
        if let url = t.link?.url { Button("Open Link") { LinkInfo.follow(url) } }
    }
}
