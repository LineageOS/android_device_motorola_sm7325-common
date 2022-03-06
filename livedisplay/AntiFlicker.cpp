/*
 * Copyright (C) 2019-2022 The LineageOS Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "AntiFlicker.h"

#include <android-base/file.h>
#include <android-base/strings.h>

namespace {
    constexpr const char *kFileDc = "/sys/devices/platform/soc/soc:qcom,dsi-display-primary/dsi_display_dc";
};  // anonymous namespace

using ::android::base::ReadFileToString;
using ::android::base::Trim;
using ::android::base::WriteStringToFile;

namespace vendor {
namespace lineage {
namespace livedisplay {
namespace V2_1 {
namespace implementation {

AntiFlicker::AntiFlicker() {
    if (!access(kFileDc, R_OK | W_OK)) {
        file_ = kFileDc;
        enabled_mode_ = 1;
    } else {
        file_ = nullptr;
    }
}

bool AntiFlicker::isSupported() {
    return file_ != nullptr;
}

// Methods from ::vendor::lineage::livedisplay::V2_1::IAntiFlicker follow.
Return<bool> AntiFlicker::isEnabled() {
    std::string tmp;
    int32_t contents = 0;

    if (ReadFileToString(file_, &tmp)) {
        contents = std::stoi(Trim(tmp));
    }

    return contents > 0;
}

Return<bool> AntiFlicker::setEnabled(bool enabled) {
    return WriteStringToFile(enabled ? std::to_string(enabled_mode_) : "0", file_, true);
}

}  // namespace implementation
}  // namespace V2_1
}  // namespace livedisplay
}  // namespace lineage
}  // namespace vendor
