# MxJobsWMS portfolio-cpp — builds with clang++ (no CMake needed; CMakeLists.txt does the same).
#   make            fetch the pinned header-only libraries (once) and build build/portfolio-cpp
#   make test       build and run the unit tests
#   make run        start the service on 127.0.0.1:8767

HTTPLIB_VERSION := v0.18.3
JSON_VERSION    := v3.11.3
CXX      ?= clang++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
INCLUDES := -Ithird_party -Isrc
LIBS     := -pthread
SOURCES  := src/optimizer.cpp src/risk.cpp src/tracking.cpp src/inputs.cpp

all: build/portfolio-cpp

third_party/httplib.h:
	@mkdir -p third_party
	curl -fsSL -o $@ https://raw.githubusercontent.com/yhirose/cpp-httplib/$(HTTPLIB_VERSION)/httplib.h

third_party/nlohmann/json.hpp:
	@mkdir -p third_party/nlohmann
	curl -fsSL -o $@ https://raw.githubusercontent.com/nlohmann/json/$(JSON_VERSION)/single_include/nlohmann/json.hpp

deps: third_party/httplib.h third_party/nlohmann/json.hpp

build/portfolio-cpp: deps src/main.cpp $(SOURCES) src/*.hpp
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(INCLUDES) src/main.cpp $(SOURCES) -o $@ $(LIBS)

build/tests: deps tests/tests.cpp $(SOURCES) src/*.hpp
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(INCLUDES) tests/tests.cpp $(SOURCES) -o $@ $(LIBS)

test: build/tests
	./build/tests

run: build/portfolio-cpp
	./build/portfolio-cpp

clean:
	rm -rf build

.PHONY: all deps test run clean
