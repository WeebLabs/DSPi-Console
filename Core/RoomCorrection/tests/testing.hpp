// Minimal dependency-free test harness.
//
// The core deliberately has no third-party dependencies, and a test framework
// is a dependency like any other.  This is enough to register cases, compare
// numbers with a tolerance, and report a useful failure line.
#pragma once

#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace testing {

struct Case {
    std::string name;
    std::function<void()> body;
};

inline std::vector<Case>& registry() {
    static std::vector<Case> cases;
    return cases;
}

inline int& failureCount() {
    static int count = 0;
    return count;
}

inline std::string& currentCase() {
    static std::string name;
    return name;
}

struct Registrar {
    Registrar(const std::string& name, std::function<void()> body) {
        registry().push_back({name, std::move(body)});
    }
};

inline void reportFailure(const char* file, int line, const std::string& message) {
    ++failureCount();
    std::printf("  FAIL %s\n    %s:%d\n    %s\n",
                currentCase().c_str(), file, line, message.c_str());
}

inline bool nearlyEqual(double a, double b, double tolerance) {
    if (std::isnan(a) || std::isnan(b)) return false;
    return std::fabs(a - b) <= tolerance;
}

inline int runAll(const char* suiteName) {
    std::printf("%s\n", suiteName);
    int passed = 0;
    for (Case& c : registry()) {
        currentCase() = c.name;
        const int before = failureCount();
        c.body();
        if (failureCount() == before) ++passed;
    }
    const int total = static_cast<int>(registry().size());
    std::printf("  %d/%d cases passed, %d assertion failures\n",
                passed, total, failureCount());
    return failureCount() == 0 ? 0 : 1;
}

}  // namespace testing

#define TEST_CASE(name)                                                       \
    static void name();                                                       \
    static ::testing::Registrar registrar_##name(#name, name);                \
    static void name()

#define CHECK(condition)                                                      \
    do {                                                                      \
        if (!(condition)) {                                                   \
            ::testing::reportFailure(__FILE__, __LINE__,                      \
                                     "expected: " #condition);                \
        }                                                                     \
    } while (false)

#define CHECK_NEAR(actual, expected, tolerance)                               \
    do {                                                                      \
        const double a_ = (actual);                                           \
        const double e_ = (expected);                                         \
        if (!::testing::nearlyEqual(a_, e_, (tolerance))) {                   \
            char buffer_[256];                                                \
            std::snprintf(buffer_, sizeof(buffer_),                           \
                          "%s = %.9g, expected %.9g (tolerance %.3g)",        \
                          #actual, a_, e_, (double)(tolerance));              \
            ::testing::reportFailure(__FILE__, __LINE__, buffer_);            \
        }                                                                     \
    } while (false)
