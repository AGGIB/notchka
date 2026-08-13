import Testing
import NotchCore
@testable import NotchUI

/// У каждой вкладки обязаны быть непустые иконка и подпись.
///
/// NotchTab.symbolName/.title сейчас написаны как switch без default, так
/// что забытый case сегодня же не даст собрать NotchUI. Но это свойство
/// конкретной реализации, а не гарантия сама по себе: default-ветка
/// («на всякий случай — questionmark для всех неизвестных») превратила бы
/// эту защиту в молчаливую дыру — колонка вкладок (TabRailView) перечисляет
/// NotchTab.allCases и никак не проверяет, что пришедшая иконка осмысленна.
/// Тест фиксирует сам инвариант, а не то, каким способом он сегодня
/// достигнут — и переживёт рефакторинг switch, который эту защиту уберёт.
@Test("у каждой вкладки есть непустые иконка и подпись")
func everyTabHasIconAndLabel() {
    for tab in NotchTab.allCases {
        #expect(!tab.symbolName.isEmpty)
        #expect(!tab.title.isEmpty)
    }
}

@Test("иконки вкладок различаются — иначе колонка нечитаема")
func tabIconsAreDistinct() {
    let symbols = NotchTab.allCases.map(\.symbolName)
    #expect(Set(symbols).count == NotchTab.allCases.count)
}

@Test("подписи вкладок различаются")
func tabTitlesAreDistinct() {
    let titles = NotchTab.allCases.map(\.title)
    #expect(Set(titles).count == NotchTab.allCases.count)
}
