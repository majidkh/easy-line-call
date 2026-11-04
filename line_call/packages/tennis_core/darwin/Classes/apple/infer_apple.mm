// Core ML ball detector (Apple only): .mlpackage on the Neural Engine.
//
// Preprocessing mirrors the Python backend exactly: BGR frames resized to
// the model input, triplets stacked (current, prev, prev-prev) BGR planar
// float32 / 255, one prediction per frame, argmax-folded "heat" output
// read back as uint8 class maps.
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstring>

#include "tennis/img.hpp"
#include "tennis/infer.hpp"

namespace tennis {

class CoreMLDetector : public BallDetector {
 public:
  CoreMLDetector(MLModel* model, MLMultiArray* scratch, int in_w, int in_h,
                 NSString* device)
      : model_(model), scratch_(scratch), in_w_(in_w), in_h_(in_h) {
    device_ = [device UTF8String];
  }
  ~CoreMLDetector() override {
    [model_ release];
    [scratch_ release];
  }

  std::string device() const override { return device_; }
  int in_w() const override { return in_w_; }
  int in_h() const override { return in_h_; }

  HeatMaps HeatmapsFor(const std::vector<const uint8_t*>& bgrs, int w, int h,
                       const std::function<bool()>& cancelled) override {
    HeatMaps out;
    const int n = (int)bgrs.size();
    if (n == 0) return out;
    // Resize all frames to model input first (matches the Python path,
    // which resizes the whole chunk up front).
    std::vector<img::Bgr> smalls;
    smalls.reserve(n);
    for (auto* p : bgrs) {
      img::Bgr f{w, h, std::vector<uint8_t>(p, p + w * h * 3)};
      smalls.push_back(img::ResizeBilinear(f, in_w_, in_h_));
    }
    out.maps.assign(n, {});
    const int plane = in_w_ * in_h_;
    float* base = (float*)scratch_.dataPointer;
    for (int i = 2; i < n; ++i) {
      if (cancelled && cancelled()) break;
      // Stack (current, prev, prev-prev), BGR planar, /255.
      for (int f = 0; f < 3; ++f) {
        const uint8_t* px = smalls[i - f].px.data();
        for (int c = 0; c < 3; ++c) {
          float* dst = base + (f * 3 + c) * plane;
          for (int k = 0; k < plane; ++k) dst[k] = px[3 * k + c] / 255.0f;
        }
      }
      NSError* err = nil;
      MLFeatureValue* fv =
          [MLFeatureValue featureValueWithMultiArray:scratch_];
      MLDictionaryFeatureProvider* in = [[MLDictionaryFeatureProvider alloc]
          initWithDictionary:@{@"frames" : fv}
                             error:&err];
      if (!in) {
        out.maps[i].assign(out.w * out.h, 0);
        continue;
      }
      id<MLFeatureProvider> pred = [model_ predictionFromFeatures:in
                                                            error:&err];
      [in release];
      if (!pred || err) {
        // Leave this map zeroed (matches Python's zeros-on-short-input
        // spirit: never crash the stream on one bad frame).
        out.maps[i].assign(out.w * out.h, 0);
        continue;
      }
      MLMultiArray* heat = [[[pred featureValueForName:@"heat"] multiArrayValue]
          retain];
      if (!heat) {
        out.maps[i].assign(out.w * out.h, 0);
        continue;
      }
      if (out.w == 0) {
        // Geometry from the first real output (models may crop borders).
        NSArray<NSNumber*>* shape = heat.shape;
        NSUInteger nd = shape.count;
        out.h = [shape[nd - 2] intValue];
        out.w = [shape[nd - 1] intValue];
        int ch = nd >= 4 ? [shape[nd - 3] intValue] : 1;
        folded_ = (ch == 1);
      }
      out.maps[i] = ReadMap(heat, out.w, out.h);
      [heat release];
    }
    if (out.w == 0) {
      out.w = in_w_;
      out.h = in_h_;
    }
    for (int i = 0; i < n; ++i)
      if (out.maps[i].empty()) out.maps[i].assign(out.w * out.h, 0);
    return out;
  }

 private:
  // Read one class map honoring arbitrary strides; argmax over the
  // channel axis when the model emits raw logits.
  std::vector<uint8_t> ReadMap(MLMultiArray* heat, int W, int H) {
    NSArray<NSNumber*>* shape = heat.shape;
    NSArray<NSNumber*>* strides = heat.strides;
    NSUInteger nd = shape.count;
    std::vector<int> st(nd);
    for (NSUInteger i = 0; i < nd; ++i) st[i] = [strides[i] intValue];
    // The buffer pointer and element type are loop-invariant; fetch
    // once instead of per pixel (an ObjC call + switch each). Same
    // values read, so the map is bit-identical.
    void* base = heat.dataPointer;
    const MLMultiArrayDataType dt = heat.dataType;
    std::vector<uint8_t> map(W * H, 0);
    if (folded_) {
      for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
          NSUInteger idx[4] = {0, 0, (NSUInteger)y, (NSUInteger)x};
          // Align trailing dims with the actual rank.
          NSUInteger off = 0;
          for (NSUInteger d = 0; d < nd; ++d)
            off += idx[4 - nd + d] * st[d];
          map[y * W + x] = (uint8_t)ScalarAt(base, dt, off);
        }
    } else {
      // Logits: argmax over the channel axis (nd-3).
      NSUInteger chd = nd - 3;
      int nch = [shape[chd] intValue];
      for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
          double best = -1e300;
          int bi = 0;
          for (int c = 0; c < nch; ++c) {
            NSUInteger idx[4] = {0, (NSUInteger)c, (NSUInteger)y, (NSUInteger)x};
            NSUInteger off = 0;
            for (NSUInteger d = 0; d < nd; ++d)
              off += idx[4 - nd + d] * st[d];
            double v = ScalarAt(base, dt, off);
            if (v > best) {
              best = v;
              bi = c;
            }
          }
          map[y * W + x] = (uint8_t)bi;
        }
    }
    return map;
  }

  static double ScalarAt(void* p, MLMultiArrayDataType dt, NSUInteger off) {
    switch (dt) {
      case MLMultiArrayDataTypeInt32:
        return ((int32_t*)p)[off];
      case MLMultiArrayDataTypeFloat32:
        return ((float*)p)[off];
      case MLMultiArrayDataTypeDouble:
        return ((double*)p)[off];
      case MLMultiArrayDataTypeFloat16: {
        // vImage-style half -> float (no Accelerate dependency here).
        uint16_t h = ((uint16_t*)p)[off];
        int s = (h >> 15) & 1, e = (h >> 10) & 31, m = h & 1023;
        double v;
        if (e == 0)
          v = m / 16777216.0;
        else if (e == 31)
          v = m ? NAN : INFINITY;
        else
          v = (m + 1024.0) / 1024.0 * pow(2.0, e - 25);
        return s ? -v : v;
      }
      default:
        return 0;
    }
  }

  MLModel* model_;
  MLMultiArray* scratch_;
  int in_w_, in_h_;
  std::string device_;
  bool folded_ = true;
};

std::unique_ptr<BallDetector> CreateDetector(const std::string& model_path,
                                             const std::string& compile_cache,
                                             const std::string& compute_units,
                                             std::string& err) {
  @autoreleasepool {
    NSError* nserr = nil;
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* pkg =
        [NSString stringWithUTF8String:model_path.c_str()];
    BOOL is_dir = NO;
    if (![fm fileExistsAtPath:pkg isDirectory:&is_dir] || !is_dir) {
      err = "model package not found: " + model_path;
      return nullptr;
    }
    // Compile once into the cache dir; reuse on later runs.
    NSDictionary* attr = [fm attributesOfItemAtPath:pkg error:nil];
    unsigned long long mtime =
        (unsigned long long)[[attr fileModificationDate] timeIntervalSince1970];
    NSString* key = [NSString
        stringWithFormat:@"%@-%llu.mlmodelc", [pkg lastPathComponent], mtime];
    NSString* cache = [NSString stringWithUTF8String:compile_cache.c_str()];
    [fm createDirectoryAtPath:cache
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    NSString* compiled = [cache stringByAppendingPathComponent:key];
    if (![fm fileExistsAtPath:compiled]) {
      NSURL* tmp = [MLModel compileModelAtURL:[NSURL fileURLWithPath:pkg]
                                        error:&nserr];
      if (!tmp || nserr) {
        err = std::string("model compile failed: ") +
              [[nserr localizedDescription] UTF8String];
        return nullptr;
      }
      [fm removeItemAtPath:compiled error:nil];
      if (![fm moveItemAtURL:tmp
                       toURL:[NSURL fileURLWithPath:compiled]
                       error:&nserr]) {
        err = std::string("model cache move failed: ") +
              [[nserr localizedDescription] UTF8String];
        return nullptr;
      }
    }
    MLModelConfiguration* config = [[MLModelConfiguration alloc] init];
    if (compute_units == "ALL")
      config.computeUnits = MLComputeUnitsAll;
    else
      config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
    MLModel* model = [[MLModel modelWithContentsOfURL:[NSURL
                                                        fileURLWithPath:compiled]
                                                       configuration:config
                                                               error:&nserr] retain];
    [config release];
    if (!model || nserr) {
      err = std::string("model load failed: ") +
            [[nserr localizedDescription] UTF8String];
      return nullptr;
    }
    // Input geometry from the model description (Turbo exports differ).
    MLFeatureDescription* fd =
        model.modelDescription.inputDescriptionsByName[@"frames"];
    int in_h = 360, in_w = 640;
    MLMultiArrayConstraint* mc = fd.multiArrayConstraint;
    if (fd && mc && mc.shape.count >= 2) {
      NSUInteger nd = mc.shape.count;
      long h = [mc.shape[nd - 2] longValue];
      long w = [mc.shape[nd - 1] longValue];
      if (h > 0 && h <= 4096) in_h = (int)h;
      if (w > 0 && w <= 4096) in_w = (int)w;
    }
    MLMultiArray* scratch = [[MLMultiArray alloc]
        initWithShape:@[ @1, @9, @(in_h), @(in_w) ]
             dataType:MLMultiArrayDataTypeFloat32
                error:&nserr];
    if (!scratch || nserr) {
      [model release];
      err = "scratch buffer alloc failed";
      return nullptr;
    }
    NSString* dev =
        [NSString stringWithFormat:@"coreml-ane:%@",
                                   compute_units == "ALL" ? @"ALL"
                                                          : @"CPU_AND_NE"];
    return std::unique_ptr<BallDetector>(
        new CoreMLDetector(model, scratch, in_w, in_h, dev));
  }
}

}  // namespace tennis
