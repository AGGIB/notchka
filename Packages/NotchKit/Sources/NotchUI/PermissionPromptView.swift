import SwiftUI

/// Что показывать во вкладке буфера обмена: объяснение разрешения или
/// саму ленту истории.
///
/// Отдельная точка ветвления, а не условие внутри вьюхи — тот же приём и та
/// же причина, что у KeyBinding.event и ClipboardCard.preview: решение «что
/// показать» проверяется тестом без окна, а не кликом по живой панели (см.
/// PermissionPromptViewTests).
public enum ClipboardTabContent: Equatable, Sendable {
    case permissionPrompt
    case ribbon

    public static func resolve(isAccessibilityTrusted: Bool) -> ClipboardTabContent {
        isAccessibilityTrusted ? .ribbon : .permissionPrompt
    }
}

/// Онбординг разрешения Accessibility — показывается во вкладке буфера
/// вместо ленты, пока разрешение не выдано (см. ClipboardTabContent).
/// Не отдельное окно и не слой поверх панели: панель — это и есть интерфейс
/// приложения, вкладка просто показывает другой шаг вместо ленты.
///
/// Сама не вызывает ни AccessibilityPermission.requestIfNeeded(), ни
/// .openSettings(): NotchUI не импортирует AppKit (Global Constraints
/// плана), поэтому обе кнопки лишь сообщают о нажатии наружу через
/// замыкания — настоящий вызов делает app-таргет (см. NotchRootView в
/// AppDelegate.swift). Из этого следует и то, что системный диалог не может
/// всплыть сам по себе при построении этой вьюхи — только по прямому
/// нажатию «Разрешить» пользователем.
public struct PermissionPromptView: View {
    private let onRequestPermission: () -> Void
    private let onOpenSettings: () -> Void

    /// Ширина текста объяснения. Область содержимого вкладки — около 514×202 pt
    /// (PanelMetrics.contentSize минус колонка вкладок и промежуток, см.
    /// NotchPanelView.tabBody), и без ограничения по ширине текст растянулся
    /// бы на всю неё одной длинной строкой вместо читаемого абзаца.
    private static let explanationWidth: CGFloat = 260

    public init(
        onRequestPermission: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onRequestPermission = onRequestPermission
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 16) {
            explanation
            buttons
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Иконка, заголовок и текст объединены в один accessibility-элемент:
    /// это описание экрана целиком, а не три независимых пункта для VoiceOver
    /// — тот же приём, что у TabPlaceholderView. Кнопки ниже сознательно вне
    /// этого блока, чтобы остаться независимо доступными с клавиатуры.
    private var explanation: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Вставка в приложения")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            // Называет действие (⌘V в активное приложение) и честно говорит
            // о запасном варианте (копирование вместо вставки), без запугивания
            // и без уговоров — так решено постановкой задачи. Коротко и
            // намеренно: контент вкладки — это всего ~202 pt высоты
            // (см. explanationWidth выше), тратить их на абзац нечем.
            Text("Клик по карточке шлёт ⌘V в активное приложение. Без разрешения история работает как обычно, а клик — просто копирует.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.explanationWidth)
        }
        .accessibilityElement(children: .combine)
    }

    /// Две кнопки, не одна: системный диалог macOS показывается один раз и
    /// потом молчит, поэтому пользователю, который его закрыл, нужен
    /// отдельный путь в Настройки. «Разрешить» — основное действие
    /// (проминентная кнопка справа, ближе к обычному месту кнопки по
    /// умолчанию в диалогах macOS), «Открыть настройки» — запасной путь.
    private var buttons: some View {
        HStack(spacing: 10) {
            PermissionButton(title: "Открыть настройки", isProminent: false, action: onOpenSettings)
            PermissionButton(title: "Разрешить", isProminent: true, action: onRequestPermission)
        }
    }
}

/// Кнопка экрана разрешения.
///
/// Проминентная — сплошная белая с чёрным текстом: тот же приём и то же
/// обоснование, что у PlayPauseButtonStyle в MusicTabView — единственное
/// намеренное исключение из «белого разной прозрачности» ради однозначно
/// кликабельной главной кнопки. Второстепенная — плашка низкой
/// непрозрачности, как неактивный пункт TabRailView. Видимый текст кнопки
/// сам по себе служит accessibility-меткой, отдельная не нужна.
private struct PermissionButton: View {
    let title: String
    let isProminent: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(PermissionButtonStyle(isProminent: isProminent, isHovering: isHovering))
        .onHover { isHovering = $0 }
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    let isProminent: Bool
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isProminent ? .black : .white.opacity(0.85))
            .background(backdrop)
            .clipShape(Capsule())
            // Нажатие отвечает мгновенно, без .animation(): тот же приём, что
            // у PlayPauseButtonStyle и TabRailItemStyle — своей анимации
            // здесь нет намеренно, заводить новую запрещает правило проекта,
            // а готовой константы подходящего порядка в NotchMotion нет.
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }

    @ViewBuilder
    private var backdrop: some View {
        if isProminent {
            Capsule().fill(.white.opacity(isHovering ? 1 : 0.88))
        } else {
            Capsule().fill(.white.opacity(isHovering ? 0.16 : 0.08))
        }
    }
}
