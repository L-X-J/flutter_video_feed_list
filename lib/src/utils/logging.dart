LogFunction? _logFunction;
set logFunction(LogFunction? func) {
  _logFunction = func;
}

void logging(String message) {
  _logFunction?.call(message);
}

typedef LogFunction = void Function(String message);
