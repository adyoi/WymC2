import UIKit

final class ViewController: UIViewController {

    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.12, blue: 0.09, alpha: 1)
        status.textColor = UIColor(red: 0.10, green: 0.80, blue: 0.47, alpha: 1)
        status.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        status.textAlignment = .center
        status.numberOfLines = 0
        status.text = "\(Config.appName)\n\(Config.server)\nheartbeat interval: \(Config.interval)s\nagent running…"
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    func setStatus(_ text: String) {
        status.text = text
    }
}