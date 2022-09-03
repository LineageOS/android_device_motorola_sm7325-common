#!/vendor/bin/sh

BASEDIR=vendor

PATH=/sbin:/$BASEDIR/sbin:/$BASEDIR/bin:/$BASEDIR/xbin
export PATH

while getopts dpfrM op;
do
	case $op in
		d)  dbg_on=1;;
		p)  populate_only=1;;
		f)  dead_touch=1;;
		r)  reset_touch=1;;
		M)  mount_2nd_stage=1;;
	esac
done
shift $(($OPTIND-1))

scriptname=${0##*/}
hw_mp=/proc/hw
config_mp=/proc/config
reboot_utag=$config_mp/.reboot
touch_status_prop=vendor.hw.touch.status
hw_cfg_file=hw_config.xml
vhw_file=/$BASEDIR/etc/vhw.xml
bp_file=/system/build.prop
oem_file=/oem/oem.prop
load_error=3
need_to_reload=2
reload_in_progress=1
reload_done=0
ver_utag=".version"
version_fs="unknown"
xml_version="unknown"
device_params=""
xml_file=""
utag_update_fail="false"
modem_ver_prop=ro.vendor.hw.modem_version
policy_prop=ro.vendor.super_image_policy

super_image_detection()
{
	local subsys
	local file2mount
	local basefile
	local version
	local extention
	local image_dir
	local is_super_image
	local super_image_prop
	local file_mount_prop
	local modem_version=$(getprop $modem_ver_prop)
	local policy=$(getprop $policy_prop)

	debug "'$policy_prop' is '$policy'"
	for subsys in modem fsg; do
		debug "Processing [${subsys}]..."
		is_super_image=""
		case ${subsys} in
			modem) image_dir=/vendor/firmware_mnt;;
			fsg)   image_dir=/vendor/fsg;;
		esac

		[ -f $image_dir/super_modem ] && is_super_image="true"
		debug "super image '$is_super_image'"

		if [ "$is_super_image" == "true" ]; then
			file2mount=""
			case ${subsys} in
				modem) super_image_prop="ro.vendor.hw.modem_super_image"
				       file_mount_prop="ro.vendor.hw.modem_mount_file"
				       basefile="NON-HLOS.bin"
				       extention=".bin"
				       [ "$modem_version" ] && file2mount=$(printf "NON-HLOS%sbin" $modem_version)
				       ;;
				fsg)   super_image_prop="ro.vendor.hw.fsg_super_image"
				       file_mount_prop="ro.vendor.hw.fsg_mount_file"
				       basefile="fsg.mbn"
				       extention=".mbn"
				       [ "$modem_version" ] && file2mount=$(printf "fsg%smbn" $modem_version)
				       ;;
			esac
			if [ -z "$file2mount" ]; then
				notice "'$modem_ver_prop' not set, but [$subsys] is super image!"
			else
				# modem_version matches existing file in super image
				if [ -f $image_dir/$file2mount ]; then
					notice "[$subsys] is super image. '$file2mount' will be mounted"
					setprop $file_mount_prop $file2mount
					setprop $super_image_prop yes
					continue
				fi
				notice "[$subsys] is super image. '$file2mount' not found"
			fi
		else
			notice "[$subsys] non-super image"
		fi

		# check super image policy
		if [ "$policy" == "enforce" ]; then
			notice "[$subsys] strict super image policy! Rebooting to recovery..."
			debug "'ro.vendor.hw.super_image_failure' -> 'yes'"
			setprop ro.vendor.hw.super_image_failure yes
			return
		fi
		notice "[$subsys] super image policy not enforced"
		# proceed with non-super image if policy allows
		if [ -z "$is_super_image" ]; then
			notice "[$subsys] proceed with non-super image!"
			continue
		fi

		# retrieve default version if available
		version=$(cat $image_dir/super_modem)
		if [ "$version" ]; then
			basefile=$version
			notice "default file override '$basefile'"
		else
			notice "use default file: '$basefile' instead of '$file2mount'"
		fi

		notice "Searching for '$basefile' in $image_dir..."
		debug "checking file '$image_dir/$basefile'"
		if [ -f $image_dir/$basefile ]; then
			notice "[$subsys] is super image! '$basefile' will be mounted"
			debug "'$file_mount_prop' -> '$basefile'"
			setprop $file_mount_prop $basefile
			debug "'$super_image_prop' -> 'yes'"
			setprop $super_image_prop yes
			continue
		fi

		# set to fail
		notice "Unable to mount '$basefile'! Rebooting to recovery..."
		debug "'ro.vendor.hw.super_image_failure' -> 'yes'"
		setprop ro.vendor.hw.super_image_failure yes
		return
	done
}

set_reboot_counter()
{
	local value=$1
	local reboot_cnt=0
	local reboot_mp=${reboot_utag%.*}
	local tag_name=${reboot_utag##*/}
	if [ $((value)) -gt 0 ]; then
		notice "increase reboot counter"
		[ -d $reboot_utag ] && reboot_cnt=$(cat $reboot_utag/ascii)
		value=$(($reboot_cnt + 1))
	fi
	if [ ! -d $reboot_utag ]; then
		echo ${reboot_utag##*/} > $reboot_mp/all/new
		[ $? != 0 ] && notice "error creating UTAG $tag_name"
	fi
	echo "$value" > $reboot_utag/ascii
	[ $? != 0 ] && notice "error updating UTAG $tag_name"
	notice "UTAG $tag_name is [`cat $reboot_utag/ascii`]"
}

set_reboot_counter_property()
{
	local reboot_cnt=0
	local tag_name=${reboot_utag##*/}
	if [ -d $reboot_utag ]; then
		reboot_cnt=$(cat $reboot_utag/ascii)
		notice "UTAG $tag_name has value [$reboot_cnt]"
	else
		notice "UTAG $tag_name does not exist"
	fi
	setprop $touch_status_prop $reboot_cnt
	notice "property [$touch_status_prop] is set to [`getprop $touch_status_prop`]"
}

debug()
{
	[ $dbg_on ] && echo "Debug: $*"
}

notice()
{
	echo "$*"
	echo "$scriptname: $*" > /dev/kmsg
}

add_device_params()
{
	device_params=$device_params" $@"
	debug "add_device_params='$device_params'"
}

drop_device_parameter()
{
	device_params=${device_params% *}
	debug "drop_device_parameter='$device_params'"
}

set_xml_file()
{
	xml_file=$@
	debug "working with XML file='$xml_file'"
}

exec_parser()
{
	eval motobox expat -u -f $xml_file $device_params "$@" 2>/dev/null
}

reload_utags()
{
	local mp=$1
	local value
	echo "1" > $mp/reload
	value=$(cat $mp/reload)
	while [ "$value" == "$reload_in_progress" ]; do
		notice "waiting for loading to complete"
		sleep 1;
		value=$(cat $mp/reload)
		notice "'$mp' current status [$value]"
	done
}

procfs_wait_for_device()
{
	local __result=$1
	local status
	local mpi
	local IFS=' '
	local device_timeout_count=0
	while [ ! -f $hw_mp/reload ] || [ ! -f $config_mp/reload ]; do
		notice "waiting for devices"
		sleep 1;
		if [ "$device_timeout_count" -eq "10" ];then
			notice "waiting for devices timeout"
			eval $__result=""
			return
		fi
		device_timeout_count=$(($device_timeout_count + 1))
        done
	for mpi in $hw_mp $config_mp; do
		status=$(cat $mpi/reload)
		notice "mount point '$mpi' status [$status]"
		if [ "$status" == "$need_to_reload" ]; then
			notice "force $mpi reloading"
			reload_utags $mpi
		fi
	done
	for mpi in $hw_mp $config_mp; do
		status=$(cat $mpi/reload)
		notice "$mpi reload is [$status]"
		device_timeout_count=0
		while [ "$status" != "$reload_done" ]; do
			notice "waiting for loading $mpi to complete"
			sleep 1;
			status=$(cat $mpi/reload)
			if [ "$device_timeout_count" -eq "10" ]; then
				notice "error: waiting for loading $mpi timeout"
				break
			fi
			device_timeout_count=$(($device_timeout_count + 1))
		done
	done
	eval $__result=$status
}

get_attr_data_by_name()
{
	local __result=$1
	local attr=$2
	shift 2
	local IFS=' '
	eval $__result=""
	for arg in ${@}; do
		[ "${arg%=*}" == "$attr" ] || continue
		debug "attr_data='${arg#*=}'"
		eval $__result="${arg#*=}"
		break
	done
}

get_tag_data()
{
	local __name=$1
	local __value=$2
	shift 2
	local dataval
	local IFS=' '
	eval $__name=""
	eval $__value=""
	for arg in ${@}; do
		case $arg in
		string-array | string)
			debug "---/ skip keyword: '$arg'"
			continue;;
		esac
		debug "---> arg='$arg'"
		if [ "${arg%=*}" == "name" ]; then
			eval $__name=${arg#*=}
			continue
		fi
		# eval treats ';' as a separator, thus make it '\;'
		dataval=$(echo ${arg#?} | sed 's/;/\\;/g')
		debug "<--- dataval='$dataval'"
		eval $__value=$dataval
	done
}

update_utag()
{
	local utag=$1
	local payload=$2
	local verify
	local rc
	if [ ! -d $hw_mp/$utag ]; then
		notice "creating utag '$utag'"
		echo $utag > $hw_mp/all/new
		rc=$?
		[ "$rc" != "0" ] && notice "'$utag' create dir failed rc=$rc"
	fi
	debug "writing '$payload' to '$hw_mp/$utag/ascii'"
	echo "$payload" > $hw_mp/$utag/ascii
	rc=$?
	if [ "$rc" != "0" ]; then
		utag_update_fail="true"
		notice "'$utag' write file failed rc=$rc"
	fi
	verify=$(cat $hw_mp/$utag/ascii)
	debug "read '$verify' from '$hw_mp/$utag/ascii'"
	[ "$verify" != "$payload" ] && notice "'$utag' payload validation failed"
}

populate_utags()
{
	local selection="$@"
	local pline
	local ptag
	local pvalue
	for pline in $(exec_parser $selection); do
		get_tag_data ptag pvalue $pline
		url_style_off pvalue $pvalue
		debug "tag='$ptag' value='$pvalue'"
		update_utag $ptag $pvalue
	done
}

set_ro_hw_properties_upgrade()
{
	local utag_path
	local utag_name
	local prop_prefix
	local utag_value
	local verify
	for hwtag in $(find $hw_mp -name '.system'); do
		debug "path $hwtag has '.system' in its name"
		prop_prefix="ro.vendor.hw."
		utag_path=${hwtag%/*}
		utag_name=${utag_path##*/}
		utag_value=$(cat $utag_path/ascii)
		setprop $prop_prefix$utag_name "$utag_value"
		notice "ro.vendor.hw.$utag_name='$utag_value'"

		if [ "$utag_name" = "dualsim" ] && [ "$utag_value" = "true" ]; then
			setprop persist.vendor.radio.multisim.config dsds
		fi
	done
}

set_ro_hw_properties()
{
	local utag_path
	local utag_name
	local prop_prefix
	local utag_value
	local verify
	for hwtag in $(find $hw_mp -name '.system'); do
		debug "path $hwtag has '.system' in its name"
		prop_prefix=$(cat $hwtag/ascii)
		verify=${prop_prefix%.}
		# esure property ends with '.'
		if [ "$prop_prefix" == "$verify" ]; then
			prop_prefix="$prop_prefix."
			debug "added '.' at the end of [$prop_prefix]"

                fi
		utag_path=${hwtag%/*}
		utag_name=${utag_path##*/}
		utag_value=$(cat $utag_path/ascii)
		setprop $prop_prefix$utag_name "$utag_value"
		notice "$prop_prefix$utag_name='$utag_value'"

		if [ "$utag_name" = "dualsim" ] && [ "$utag_value" = "true" ]; then
			setprop persist.vendor.radio.multisim.config dsds
		fi
	done
}

set_ro_vendor_incremental()
{
	local vendor_incremental="ro.vendor.build.version.incremental"
	local vendor_incremental_value
	local fetch_prop="ro.build.version.incremental"
        local fetch_value=$(getprop $fetch_prop)

        [ -z "$fetch_value" ] && prefetch_from_file $fetch_prop vendor_incremental_value
	setprop $vendor_incremental "$vendor_incremental_value"
        notice "$vendor_incremental='$vendor_incremental_value'"
}

smart_value()
{
	local mtag=$1
	local __result=$2
	local value
	eval $__result=""
	local tmp=${mtag#?}
	# absolute path to the file starts with '/'
	if [ "${mtag%$tmp}" == "/" ]; then
		value=$(cat $mtag)
	# property likely to have '.'
	elif [ "$mtag" != "${mtag%.*}" ]; then
		value=$(getprop $mtag)
	else	# tag otherwise
		value=$(cat $hw_mp/$mtag/ascii)
	fi
	eval $__result='$value'
}

url_style_off()
{
	local __arg=$1
	local value=$2
	if [[ $value == *%* ]]; then
		value=$(echo $value | sed 's/%20/ /g')
		value=$(echo $value | sed 's/%28/\(/g')
		value=$(echo $value | sed 's/%29/\)/g')
	fi
	eval $__arg='$value'
}

match()
{
	local mapping
	local mline
	local mtag
	local fs_value
	local mvalue
	local matched
	url_style_off mapping $1
	debug "match mapping='$mapping'"
	# put '\"' around $mapping to ensure XML
	# parser takes it as a single argument
	for mline in $(exec_parser \"$mapping\"); do
		get_tag_data mtag mvalue $mline
		url_style_off mvalue $mvalue
		# obtain value based on data source: utag, property or file
		smart_value $mtag fs_value
		if [ "$fs_value" == "$mvalue" ]; then
			matched="true";
		else
			matched="false";
		fi
		debug "cmp utag='$mtag' values '$mvalue' & '$fs_value' is \"$matched\""
		[ "$matched" == "false" ] && break
	done
	[ "$matched" == "true" ] && return 0
	return 1
}

find_match()
{
	local __retval=$1
	local tag_name
	local fline
	local line
	local subsection
	local matched="false"
	eval $__retval=""
	for fline in $(exec_parser); do
		subsection=${fline%% *}
		add_device_params $subsection
		for line in $(exec_parser); do
			get_attr_data_by_name tag_name "name" $line
			debug "tag_name='$tag_name'"
			match $tag_name
			[ "$?" != "0" ] && continue
			eval $__retval=$tag_name
			matched="true"
			break
		done
		drop_device_parameter
		[ "$matched" == "true" ] && break
	done
}

prefetch_from_file()
{
	local pname=$1
	local __result=$2
	local value
	local override
	eval $__result=""
	value=$(cat $bp_file 2>/dev/null | sed '/^$/d' | sed '/^#/d' | sed '/^import/d' | sed -n "/$pname=/p" | sed 's/.*=//')
	debug "'$pname' from '$bp_file': '$value'"
	if [ -f $oem_file ]; then
		override=$(cat $oem_file 2>/dev/null | sed '/^$/d' | sed '/^#/d' | sed '/^import/d' | sed -n "/$pname=/p" | sed 's/.*=//')
		[ "$override" ] && value=$override && debug "'$pname' from '$oem_file': '$value'"
	fi
	eval $__result=$value
}

append_match()
{
	local prop_list=$1
	local suffix="$2"
	local dest_prop
	local fetched_prop
	local prop_value
	local IFS=','
	# properties list to put the result of appending hw suffix to
	# example: appended="ro.vendor.product.name,ro.vendor.product.device"
	for dest_prop in $prop_list; do
		fetch_prop=${dest_prop}
		# only alter property name that has "vendor" in it
		if [ "${fetch_prop//.vendor}" != "$dest_prop" ]; then
			fetch_prop=${fetch_prop//.vendor}
			prop_value=$(getprop $fetch_prop)
			[ -z "$prop_value" ] && prefetch_from_file $fetch_prop prop_value
			# finally set destination property to appended value
			setprop $dest_prop "$prop_value$suffix"
			notice "$dest_prop='$prop_value$suffix'"
		fi
	done
}

process_mappings()
{
	local pname=""
	local pexport=""
	local pdefault=""
	local pappend=""
	local putag=""
	local subsection
	local pline
	local matched_val
	local whitespace_val
	local export_val
	local utag_val
	for pline in $(exec_parser); do
		subsection=${pline%% *}
		debug "subsection is '$subsection'"
		get_attr_data_by_name pname "name" $pline
		get_attr_data_by_name pexport "export" $pline
		get_attr_data_by_name pdefault "default" $pline
		get_attr_data_by_name pappend "append" $pline
		get_attr_data_by_name putag "writeback" $pline
		[ "$pname" ] && url_style_off pname $pname && debug "name='$pname'"
		[ "$pexport" ] && url_style_off pexport $pexport && debug "export='$pexport'"
		[ "$pdefault" ] && url_style_off pdefault $pdefault && debug "default='$pdefault'"
		[ "$pappend" ] && url_style_off pappend $pappend && debug "append='$pappend'"
		# add 'subsection' to permanent parameters
		add_device_params $subsection
		# call itself here to handle nonamed subsection, like quirks
		[ -z "$pname" ] && [ -z "$pexport" ] && [ -z "$pdefault" ] && [ -z "$pappend" ] && [ -z "$putag" ] && process_mappings && continue
		find_match matched_val
		[ "$matched_val" ] && url_style_off matched_val $matched_val
		# append_match handles OEM overrides, thus has to be called even with empty value
		[ "$pappend" ] && append_match $pappend "$matched_val"
		if [ "$matched_val" ]; then
			if [ "$pexport" ]; then
				setprop $pexport "$matched_val"
				notice "exporting '$matched_val' into property $pexport"
			fi
		elif [ "$pexport" -a "$pdefault" ]; then
			# if match is not found, proceed with default
			setprop $pexport "$pdefault"
			notice "defaulting '$pdefault' into property $pexport"
		fi

		if [ "$putag" ] && [ -d $hw_mp/$putag ]; then
			export_val=$(getprop $pexport)
			utag_val=$(cat $hw_mp/$putag/ascii)
			debug "writeback compare $utag_val,$export_val"
			# if property is empty value, clear the utag.
			# if property and writeback utag are empty value, don't update utag
			if [ "$export_val" -o "$utag_val" != "(null)" ] && [ "$utag_val" != "$export_val" ]; then
				update_utag $putag $export_val
				notice "writeback '$export_val' into utag $putag"
			fi
		fi
		# remove the last added parameter
		drop_device_parameter
	done
}

# Main starts here
IFS=$'\n'

if [ ! -z "$mount_2nd_stage" ]; then
	notice "Super image detection"
	super_image_detection
	return 0
fi

if [ ! -z "$reset_touch" ]; then
	notice "reset reboot counter"
	set_reboot_counter 0
	return 0
fi

if [ ! -z "$dead_touch" ]; then
	notice "property [$touch_status_prop] set to [dead]"
	set_reboot_counter 1
	return 0
fi

if [ -f /vendor/lib/modules/utags.ko ]; then
	notice "loading utag driver"
	insmod /vendor/lib/modules/utags.ko
	if [ $? -ne 0 ]; then
		gki_modules_full_path=`find /vendor/lib/modules -name "*-gki"`
		if [ -n "$gki_modules_full_path" ]; then
			gki_modules_path=`basename $gki_modules_full_path`
			notice "loading gki utag driver in /vendor/lib/modules/$gki_modules_path"
			insmod /vendor/lib/modules/$gki_modules_path/utags.ko
			if [ $? -ne 0 ]; then
				notice "fail to load /vendor/lib/modules/$gki_modules_path/utags.ko"
				setprop ro.vendor.mot.gki.path "."
			else
				notice "successfully load /vendor/lib/modules/$gki_modules_path/utags.ko"
				setprop ro.vendor.mot.gki.path $gki_modules_path
			fi
		else
			notice "fail to load utag driver"
			setprop ro.vendor.mot.gki.path "."
		fi
	else
		setprop ro.vendor.mot.gki.path "."
	fi
fi

notice "checking integrity"
# check necessary components exist and just proceed
# with RO properties setup otherwise
if [ ! -f /$BASEDIR/bin/expat ] || [ ! -f $vhw_file ]; then
	notice "warning: missing expat or xml"
	set_ro_hw_properties
	return 0
fi

if [ ! -z "$populate_only" ]; then
	# special handling for factory UTAGs provisioning
	for path in /data/local/tmp /pds/factory; do
		[ -f $path/$hw_cfg_file ] && break
	done
	notice "populating hw config from '$path/$hw_cfg_file'"
	set_xml_file $path/$hw_cfg_file
	populate_utags hardware
	return 0
fi

notice "initializing procfs"
procfs_wait_for_device readiness
if [ "$readiness" != "0" ]; then
	notice "no access to hw utags procfs"
	return 1
fi

# populate touch status property with reboot counter
set_reboot_counter_property &

# XML parsing starts here
set_xml_file $vhw_file

get_attr_data_by_name boot_device_prop "match" $(exec_parser)
debug "attr='get' value='$boot_device_prop'"
if [ -z $boot_device_prop ]; then
	notice "fatal: undefined boot device property"
	return 1
fi

# ensure lower case
typeset -l boot_device=$(getprop $boot_device_prop)
# drop suffixes
boot_device=${boot_device%[_-]*}
notice "matching to boot device '$boot_device'"

# add 'validation' to permanent parameters
add_device_params validation

for line in $(exec_parser); do
	get_attr_data_by_name product "name" $line
	debug "attr='name' value='$product'"
	if [ "$product" == "$boot_device" ]; then
		get_attr_data_by_name xml_version "version" $line
		[ "$xml_version" != "unknown" ] && notice "device '$boot_device' xml version='$xml_version'"
		break
	fi
done

[ "$xml_version" == "unknown" ] && notice "no match found for device '$boot_device'"
# delete obsolete 'version' utag if exists
[ -d $hw_mp/${ver_utag#?} ] && $(echo ${ver_utag#?} > $hw_mp/all/delete)
# read procfs version
[ -d $hw_mp/$ver_utag ] && version_fs=$(cat $hw_mp/$ver_utag/ascii)
notice "procfs version='$version_fs'"
# add 'device' and '$boot_device' to permanent parameters
add_device_params device $boot_device
[ "$xml_version" == "$version_fs" ] && notice "hw descriptor is up to date"
for section in $(exec_parser); do
	debug "section='$section'"
	case $section in
	mappings)
		# add 'mappings' to permanent parameters
		add_device_params $section
		process_mappings &
		;;
	*)
		[ "$xml_version" == "$version_fs" ] && continue
		populate_utags $section;;
	esac
done

if [ "$xml_version" != "$version_fs" ]; then
	# create version utag if it's missing
	[ ! -d $hw_mp/$ver_utag ] && $(echo "$ver_utag" > $hw_mp/all/new)
	# update procfs version
	[ -d $hw_mp/$ver_utag ] && $(echo "$xml_version" > $hw_mp/$ver_utag/ascii)
fi

set_ro_vendor_incremental &

set_ro_hw_properties

if [ "$utag_update_fail" == "true" ]; then
	set_ro_hw_properties_upgrade
fi

wait

notice "script init.oem.hw.sh finish "
return 0

