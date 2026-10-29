#include <onnxruntime/onnxruntime_cxx_api.h>
#include <iostream>
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  try {
    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "fold-speaker");
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(1);
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_BASIC);
    options.SetOptimizedModelFilePath(argv[2]);
    Ort::Session session(env, argv[1], options);
    return 0;
  } catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
