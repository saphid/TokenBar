.PHONY: build release run install clean

APP_NAME    = TokenBar
BUILD_DIR   = .build/release
APP_BUNDLE  = $(APP_NAME).app

# Debug build + run
run:
	swift build
	.build/debug/$(APP_NAME)

# Release build
release:
	swift build -c release

# Create .app bundle from release build
build: release
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@echo "Built $(APP_BUNDLE)"

# Install to /Applications
install: build
	@echo "Installing to /Applications/$(APP_BUNDLE)..."
	@rm -rf /Applications/$(APP_BUNDLE)
	@cp -r $(APP_BUNDLE) /Applications/
	@echo "Installed. Launch from /Applications or Spotlight."

# Clean everything
clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
