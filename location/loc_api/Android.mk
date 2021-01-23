ifneq ($(QCPATH),)
ifneq ($(BOARD_VENDOR_QCOM_GPS_LOC_API_HARDWARE),)

LOCAL_PATH := $(call my-dir)
include $(call all-subdir-makefiles)

endif#BOARD_VENDOR_QCOM_GPS_LOC_API_HARDWARE
endif #QCPATH
