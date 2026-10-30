extends GutHookScript
## Gives the Netcode autoload the logger a consuming game would
## set before initialize(): the addon's code calls Netcode.log
## from constructors (e.g. CircularBuffer._init), and in this
## harness nothing else provides one (RN3).


func run() -> void:
	if Netcode.log == null:
		Netcode.log = NetworkLogger.new()
	if Netcode.settings == null:
		Netcode.settings = NetworkSettings.new()
	if not Netcode._is_initialized:
		Netcode.initialize()
