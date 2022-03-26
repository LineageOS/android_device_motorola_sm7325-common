LOCAL_PATH := $(call my-dir)
include $(call all-makefiles-under,$(LOCAL_PATH))

GNSS_SANITIZE := cfi bounds null unreachable integer
# Activate the following two lines for regression testing
# GNSS_SANITIZE += address
# GNSS_SANITIZE_DIAG := $(GNSS_SANITIZE)
