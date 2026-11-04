// Minimal JSON value + parser (objects, arrays, strings, numbers,
// true/false/null). Enough for parity fixtures; no dependencies.
#pragma once

#include <cctype>
#include <cstdint>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace mini {

struct Value;
using Object = std::map<std::string, std::shared_ptr<Value>>;
using Array = std::vector<std::shared_ptr<Value>>;

struct Value {
  enum class Type { Null, Bool, Num, Str, Arr, Obj } type = Type::Null;
  bool b = false;
  double num = 0;
  std::string str;
  Array arr;
  Object obj;
  bool is_null() const { return type == Type::Null; }
  double as_num() const { return num; }
  int as_int() const { return static_cast<int>(num); }
  bool as_bool() const { return b; }
  const std::string& as_str() const { return str; }
  const Array& as_arr() const { return arr; }
  const Object& as_obj() const { return obj; }
  const Value& at(const std::string& k) const {
    auto it = obj.find(k);
    if (it == obj.end()) throw std::runtime_error("missing key: " + k);
    return *it->second;
  }
};

inline std::shared_ptr<Value> Parse(const std::string& s, size_t& p) {
  auto v = std::make_shared<Value>();
  while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
  if (p >= s.size()) throw std::runtime_error("unexpected end of json");
  char c = s[p];
  if (c == '{') {
    v->type = Value::Type::Obj;
    ++p;
    while (true) {
      while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
      if (s[p] == '}') {
        ++p;
        break;
      }
      if (s[p] != '"') throw std::runtime_error("expected string key");
      ++p;
      std::string k;
      while (s[p] != '"') {
        if (s[p] == '\\') ++p;
        k += s[p++];
      }
      ++p;
      while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
      if (s[p] != ':') throw std::runtime_error("expected :");
      ++p;
      v->obj[k] = Parse(s, p);
      while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
      if (s[p] == ',') {
        ++p;
        continue;
      }
      if (s[p] == '}') {
        ++p;
        break;
      }
      throw std::runtime_error("expected , or }");
    }
  } else if (c == '[') {
    v->type = Value::Type::Arr;
    ++p;
    while (true) {
      while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
      if (s[p] == ']') {
        ++p;
        break;
      }
      v->arr.push_back(Parse(s, p));
      while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
      if (s[p] == ',') {
        ++p;
        continue;
      }
      if (s[p] == ']') {
        ++p;
        break;
      }
      throw std::runtime_error("expected , or ]");
    }
  } else if (c == '"') {
    v->type = Value::Type::Str;
    ++p;
    while (s[p] != '"') {
      if (s[p] == '\\') ++p;
      v->str += s[p++];
    }
    ++p;
  } else if (s.compare(p, 4, "true") == 0) {
    v->type = Value::Type::Bool;
    v->b = true;
    p += 4;
  } else if (s.compare(p, 5, "false") == 0) {
    v->type = Value::Type::Bool;
    v->b = false;
    p += 5;
  } else if (s.compare(p, 4, "null") == 0) {
    v->type = Value::Type::Null;
    p += 4;
  } else {
    v->type = Value::Type::Num;
    size_t e = p;
    while (e < s.size() &&
           (std::isdigit((unsigned char)s[e]) || s[e] == '.' || s[e] == '-' ||
            s[e] == '+' || s[e] == 'e' || s[e] == 'E'))
      ++e;
    v->num = std::stod(s.substr(p, e - p));
    p = e;
  }
  return v;
}

inline std::shared_ptr<Value> ParseJson(const std::string& s) {
  size_t p = 0;
  auto v = Parse(s, p);
  return v;
}

}  // namespace mini
