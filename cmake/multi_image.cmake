#
# Copyright (c) 2019 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#

include_guard(GLOBAL)

if(SYSBUILD)
  # Sysbuild and child-image are mutual exclusive, so if sysbuild is used disable child-image
  function(add_child_image)
    set(CONFIG_USE_PARTITION_MANAGER n CACHE INTERNAL "")
    # ignore, sysbuild is in use.
  endfunction()
  return()
endif()

if(IMAGE_NAME)
  set_shared(IMAGE ${IMAGE_NAME} PROPERTY KERNEL_HEX_NAME ${KERNEL_HEX_NAME})
  set_shared(IMAGE ${IMAGE_NAME} PROPERTY ZEPHYR_BINARY_DIR ${ZEPHYR_BINARY_DIR})
  # Share the elf file, in order to support symbol loading for debuggers.
  set_shared(IMAGE ${IMAGE_NAME} PROPERTY KERNEL_ELF_NAME ${KERNEL_ELF_NAME})
  set_shared(IMAGE ${IMAGE_NAME}
    PROPERTY BUILD_BYPRODUCTS
             ${PROJECT_BINARY_DIR}/${KERNEL_HEX_NAME}
             ${PROJECT_BINARY_DIR}/${KERNEL_ELF_NAME}
  )
  # Share the signing key file so that the parent image can use it to
  # generate signed update candidates.
  if(CONFIG_BOOT_SIGNATURE_KEY_FILE)
    set_shared(IMAGE ${IMAGE_NAME} PROPERTY SIGNATURE_KEY_FILE ${CONFIG_BOOT_SIGNATURE_KEY_FILE})
  endif()

  generate_shared(IMAGE ${IMAGE_NAME} FILE ${CMAKE_BINARY_DIR}/shared_vars.cmake)
else()
  # Store a preload file with whatever configurations are required to create
  # a variant build of this image (that is, 'app'). Copy relevant information
  # from the 'app' image CMakeCache in order to build an identical variant image.
  # In general, what we need to copy is the arguments passed by the user
  # through command line arguments. These can typically be identified by
  # inspecting their help text. However, some variables have special
  # handling, resulting in a different help text. These cannot be found
  # using the same mechanisms as the regular variables, and needs special
  # handling.

  # Add a custom target similar to that created when adding a child image
  # to facilitate the process of creating a variant image of the app image.
  add_custom_target(app_subimage)

  set(base_image_preload_file ${CMAKE_BINARY_DIR}/image_preload.cmake)

  file(
    WRITE
    ${base_image_preload_file}
    "# Generated file that can be used to preload variant images\n"
    )

  get_cmake_property(variables_cached CACHE_VARIABLES)
  foreach(var_name ${variables_cached})
    # If '-DCONF_FILE' is specified, it is unset by boilerplate.cmake and
    # replaced with 'CACHED_CONF_FILE' in the cache. Therefore we need this
    # special handling for passing the value to the variant image.
    if("${var_name}" MATCHES "CACHED_CONF_FILE")
      list(APPEND application_vars ${var_name})
    endif()

    # If 'CACHED_CONF_FILE' is specified instead of 'CONF_FILE', the build system does not determine
    # build type automatically. In that case, the 'CONF_FILE_BUILD_TYPE' shall be passed explicitly.
    if("${var_name}" MATCHES "CONF_FILE_BUILD_TYPE")
      list(APPEND application_vars ${var_name})
    endif()

    # '-DDTC_OVERLAY_FILE' is given helptext by the build system. Therefore
    # we need this special handling for passing the value to the variant image.
    if("${var_name}" MATCHES "DTC_OVERLAY_FILE")
      list(APPEND application_vars ${var_name})
    endif()

    # All CONFIG_.* and CLI_CONFIG_* variables are given helptext by the build
    # system. Therefore we need this special handling for passing the value to
    # the variant image.
    if("${var_name}" MATCHES "^CONFIG_.*" OR
       "${var_name}" MATCHES "^CLI_CONFIG_.*"
    )
      list(APPEND application_vars ${var_name})
    endif()

    # Command line arguments can generally be identified in the CMakeCache
    # because they have the same help text generated by CMake. The text:
    # - "No help, variable specified on the command line."
    # - "Selected <var-name-lower>" command line variables updated by Zephyr.
    get_property(var_help CACHE ${var_name} PROPERTY HELPSTRING)
    string(TOLOWER ${var_name} var_name_lower)
    if("${var_help}" STREQUAL "No help, variable specified on the command line." OR
       "${var_help}" STREQUAL "Selected ${var_name_lower}")
      list(APPEND application_vars ${var_name})
    endif()
  endforeach()

  foreach(app_var_name ${application_vars})
    string(REPLACE "\"" "\\\"" app_var_value "$CACHE{${app_var_name}}")
    file(
      APPEND
      ${base_image_preload_file}
      "set(${app_var_name} \"${app_var_value}\" CACHE INTERNAL \"NCS child image controlled\")\n"
      )
  endforeach()

  set_property(
    TARGET app_subimage
    PROPERTY preload_file
    ${base_image_preload_file}
    )

  set_property(
    TARGET app_subimage
    PROPERTY source_dir
    ${APPLICATION_SOURCE_DIR}
    )

  set_property(
    TARGET app_subimage
    PROPERTY binary_dir
    ${CMAKE_BINARY_DIR}
    )
endif(IMAGE_NAME)

function(add_child_image)
  # Adds a child image to the build.
  #
  # Required arguments are:
  # NAME - The name of the child image
  # SOURCE_DIR - The source dir of the child image, not required if
  #              PRELOAD_IMAGE is set.
  #
  # Optional arguments are:
  # DOMAIN - The domain to place the child image in.
  # PRELOAD_IMAGE - Use preload file from this image instead of using standard
  #                 mechanisms for locating child image configurations.
  #                 Set this to "app" to use the preload file from the "root"
  #                 image (that is, the only non-child-image in the build).
  #
  # Depending on the value of CONFIG_${NAME}_BUILD_STRATEGY the child image
  # is either built from source, included as a hex file, or ignored.
  #
  # See chapter "Multi-image builds" in the documentation for more details.

  # Don't add child images when building variant images.
  if (CONFIG_NCS_IS_VARIANT_IMAGE)
    return()
  endif()

  set(oneValueArgs NAME SOURCE_DIR DOMAIN PRELOAD_IMAGE)
  cmake_parse_arguments(ACI "" "${oneValueArgs}" "" ${ARGN})

  if (NOT ACI_NAME OR NOT (ACI_SOURCE_DIR OR ACI_PRELOAD_IMAGE))
    message(FATAL_ERROR "Missing parameter, required: NAME and (SOURCE_DIR or PRELOAD_IMAGE)")
  endif()

  if (NOT CONFIG_PARTITION_MANAGER_ENABLED)
    message(FATAL_ERROR
      "CONFIG_PARTITION_MANAGER_ENABLED was not set for image ${ACI_NAME}."
      "This option must be set for an image to support being added as a child"
      "image through 'add_child_image'. This is typically done by invoking the"
      " `build_strategy` kconfig template for the child image.")
  endif()

  string(TOUPPER ${ACI_NAME} UPNAME)

  if (CONFIG_${UPNAME}_BUILD_STRATEGY_USE_HEX_FILE)
    assert_exists(CONFIG_${UPNAME}_HEX_FILE)
    message("Using ${CONFIG_${UPNAME}_HEX_FILE} instead of building ${ACI_NAME}")

    # Set property so that the hex file is merged in by partition manager.
    set_property(GLOBAL PROPERTY ${ACI_NAME}_PM_HEX_FILE ${CONFIG_${UPNAME}_HEX_FILE})
  elseif (CONFIG_${UPNAME}_BUILD_STRATEGY_SKIP_BUILD)
    message("Skipping building of ${ACI_NAME}")
  else()
    # Build normally
    add_child_image_from_source(${ARGN})
  endif()
endfunction()

function(add_child_image_from_source)
  # See 'add_child_image'
  set(oneValueArgs NAME SOURCE_DIR DOMAIN BOARD PRELOAD_IMAGE)
  cmake_parse_arguments(ACI "" "${oneValueArgs}" "" ${ARGN})

  if (NOT ACI_NAME OR NOT (ACI_SOURCE_DIR OR ACI_PRELOAD_IMAGE))
    message(FATAL_ERROR "Missing parameter, required: NAME and (SOURCE_DIR or PRELOAD_IMAGE)")
  endif()

  # Pass information that the partition manager is enabled to Kconfig.
  add_overlay_config(
    ${ACI_NAME}
    ${ZEPHYR_NRF_MODULE_DIR}/subsys/partition_manager/partition_manager_enabled.conf
    )

  if (${ACI_NAME}_BOARD)
    message(FATAL_ERROR
      "${ACI_NAME}_BOARD set in outer scope. Will be ignored, use "
      "`add_child_image(BOARD ${${ACI_NAME}_BOARD} ...)` for adding a child "
      "image for specific board")
  endif()

  # Add the new partition manager domain if needed.
  # The domain corresponds to the BOARD without the 'ns' suffix.
  if (ACI_DOMAIN)
    if ("${ACI_BOARD}" STREQUAL "")
      message(FATAL_ERROR
        "No board specified for domain '${ACI_DOMAIN}'. This configuration is "
        "typically defined in ${BOARD_DIR}/Kconfig")
    endif()

    set(domain_parent ${${ACI_DOMAIN}_PM_DOMAIN_DYNAMIC_PARTITION})
    if(DEFINED ${ACI_DOMAIN}_PM_DOMAIN_DYNAMIC_PARTITION
       AND NOT "${domain_parent}" STREQUAL "${ACI_NAME}"
    )
      # A domain may only have one child image, which can then act as a parent
      # to other images in the domain.
      # As it is a cache variable we check it's content so that CMake re-run
      # will pass the check as long as the child image hasn't changed.
      message(FATAL_ERROR "A domain may only have a single child image."
        "Current domain image is: ${domain_parent}, `${domain_parent}` is a "
	"domain parent image, so you may add `${ACI_NAME}` as a child inside "
	"`${domain_parent}`"
      )
    endif()
    # This needs to be made globally available as it is used in other files.
    set(${ACI_DOMAIN}_PM_DOMAIN_DYNAMIC_PARTITION ${ACI_NAME} CACHE INTERNAL "")

    if (NOT (${ACI_DOMAIN} IN_LIST PM_DOMAINS))
      list(APPEND PM_DOMAINS ${ACI_DOMAIN})
      set_property(GLOBAL APPEND PROPERTY PM_DOMAINS ${ACI_DOMAIN})
    endif()
  elseif (NOT ACI_BOARD)
    # No BOARD is given as argument, this triggers automatic conversion of
    # *.ns board from parent image.
    get_board_without_ns_suffix(${BOARD}${BOARD_QUALIFIERS} ACI_BOARD)
  endif()

  if (NOT ACI_DOMAIN AND DOMAIN)
    # If no domain is specified, a child image will inherit the domain of
    # its parent.
    set(ACI_DOMAIN ${DOMAIN})
    set(inherited " (inherited)")
  endif()

  set(${ACI_NAME}_DOMAIN ${ACI_DOMAIN})
  set(${ACI_NAME}_BOARD ${ACI_BOARD})

  message("\n=== child image ${ACI_NAME} - ${ACI_DOMAIN}${inherited} begin ===")

  if (CONFIG_BOOTLOADER_MCUBOOT)
    list(APPEND extra_cmake_args "-DCONFIG_NCS_MCUBOOT_IN_BUILD=y")
  endif()

  if (ACI_PRELOAD_IMAGE)
    get_property(
      preload_file
      TARGET ${ACI_PRELOAD_IMAGE}_subimage
      PROPERTY preload_file
      )

    get_property(
      source_dir
      TARGET ${ACI_PRELOAD_IMAGE}_subimage
      PROPERTY source_dir
      )

    get_property(
      binary_dir
      TARGET ${ACI_PRELOAD_IMAGE}_subimage
      PROPERTY binary_dir
      )

    list(APPEND extra_cmake_args "-DCONFIG_NCS_IS_VARIANT_IMAGE=y")
    list(APPEND extra_cmake_args "-DPRELOAD_BINARY_DIR=${binary_dir}")
  else()
    set(source_dir ${ACI_SOURCE_DIR})

    # It is possible for a sample to use a custom set of Kconfig fragments for a
    # child image, or to append additional Kconfig fragments to the child image.
    # Note that <ACI_NAME> in this context is the name of the child image as
    # passed to the 'add_child_image' function.
    #
    # <child-sample> DIRECTORY
    # | - prj.conf (A)
    # | - prj_<buildtype>.conf (B)
    # | - boards DIRECTORY
    # | | - <board>.conf (C)
    # | | - <board>_<buildtype>.conf (D)


    # <current-sample> DIRECTORY
    # | - prj.conf
    # | - prj_<buildtype>.conf
    # | - child_image DIRECTORY
    #     |-- <ACI_NAME>.conf (I)                 Fragment, used together with (A) and (C)
    #     |-- <ACI_NAME>_<buildtype>.conf (J)     Fragment, used together with (B) and (D)
    #     |-- <ACI_NAME>.overlay                  If present, will be merged with BOARD.dts
    #     |-- <ACI_NAME> DIRECTORY
    #         |-- boards DIRECTORY
    #         |   |-- <board>.conf (E)            If present, use instead of (C), requires (G).
    #         |   |-- <board>_<buildtype>.conf (F)     If present, use instead of (D), requires (H).
    #         |   |-- <board>.overlay             If present, will be merged with BOARD.dts
    #         |   |-- <board>_<revision>.overlay  If present, will be merged with BOARD.dts
    #         |-- prj.conf (G)                    If present, use instead of (A)
    #         |                                   Note that (C) is ignored if this is present.
    #         |                                   Use (E) instead.
    #         |-- prj_<buildtype>.conf (H)        If present, used instead of (B) when user
    #         |                                   specify `-DCONF_FILE=prj_<buildtype>.conf for
    #         |                                   parent image. Note that any (C) is ignored
    #         |                                   if this is present. Use (F) instead.
    #         |-- <board>.overlay                 If present, will be merged with BOARD.dts
    #         |-- <board>_<revision>.overlay      If present, will be merged with BOARD.dts
    #
    # Note: The folder `child_image/<ACI_NAME>` is only need when configurations
    #       files must be used instead of the child image default configs.
    #       The append a child image default config, place the additional settings
    #       in `child_image/<ACI_NAME>.conf`.
    zephyr_get(COMMON_CHILD_IMAGE_CONFIG_DIR)
    string(CONFIGURE "${COMMON_CHILD_IMAGE_CONFIG_DIR}" COMMON_CHILD_IMAGE_CONFIG_DIR)
    foreach(config_dir ${APPLICATION_CONFIG_DIR} ${COMMON_CHILD_IMAGE_CONFIG_DIR} )
      set(ACI_CONF_DIR ${config_dir}/child_image)
      set(ACI_NAME_CONF_DIR ${config_dir}/child_image/${ACI_NAME})
      if (NOT ${ACI_NAME}_CONF_FILE)
        if(DEFINED CONF_FILE_BUILD_TYPE AND DEFINED ${ACI_NAME}_FILE_SUFFIX)
          message(WARNING "Cannot use BUILD_TYPE='${CONF_FILE_BUILD_TYPE}' together with ${ACI_NAME}_FILE_SUFFIX='${${ACI_NAME}_FILE_SUFFIX}'. "
                          "Ignoring BUILD_TYPE='${CONF_FILE_BUILD_TYPE}'"
          )
	else()
	  set(LEGACY_BUILD_ARGUMENT BUILD ${CONF_FILE_BUILD_TYPE})
	endif()
        ncs_file(CONF_FILES ${ACI_NAME_CONF_DIR}
          BOARD ${ACI_BOARD}
          # Child image always uses the same revision as parent board.
          BOARD_REVISION ${BOARD_REVISION}
          KCONF ${ACI_NAME}_CONF_FILE
          DTS ${ACI_NAME}_DTC_OVERLAY_FILE
          ${LEGACY_BUILD_ARGUMENT}
          SUFFIX ${${ACI_NAME}_FILE_SUFFIX}
          )
        # Place the result in the CMake cache and remove local scoped variable.
        foreach(file CONF_FILE DTC_OVERLAY_FILE)
          if(DEFINED ${ACI_NAME}_${file})
            set(${ACI_NAME}_${file} ${${ACI_NAME}_${file}} CACHE STRING
              "Default ${ACI_NAME} configuration file" FORCE
              )
            set(${ACI_NAME}_${file})
          endif()
        endforeach()

        # Check for configuration fragment. The contents of these are appended
        # to the project configuration, as opposed to the CONF_FILE which is used
        # as the base configuration.
        if(DEFINED ${ACI_NAME}_FILE_SUFFIX)
          # Child/parent image does not support a prefix for the main application, therefore only
          # use child image configuration with suffixes if specifically commanded with an argument
          # targeting this child image
          set(child_image_conf_fragment ${ACI_CONF_DIR}/${ACI_NAME}.conf)
          zephyr_file_suffix(child_image_conf_fragment SUFFIX ${${ACI_NAME}_FILE_SUFFIX})
        elseif(NOT "${CONF_FILE_BUILD_TYPE}" STREQUAL "")
          set(child_image_conf_fragment ${ACI_CONF_DIR}/${ACI_NAME}_${CONF_FILE_BUILD_TYPE}.conf)
        else()
          set(child_image_conf_fragment ${ACI_CONF_DIR}/${ACI_NAME}.conf)
        endif()
        if (EXISTS ${child_image_conf_fragment})
          add_overlay_config(${ACI_NAME} ${child_image_conf_fragment})
        endif()

        # Check for overlay named <ACI_NAME>.overlay.
        set(child_image_dts_overlay ${ACI_CONF_DIR}/${ACI_NAME}.overlay)
        zephyr_file_suffix(child_image_dts_overlay SUFFIX ${${ACI_NAME}_FILE_SUFFIX})
        if (EXISTS ${child_image_dts_overlay})
          add_overlay_dts(${ACI_NAME} ${child_image_dts_overlay})
        endif()

        if(${ACI_NAME}_CONF_FILE OR ${ACI_NAME}_DTC_OVERLAY_FILE
           OR EXISTS ${child_image_conf_fragment} OR EXISTS ${child_image_dts_overlay})
           # If anything is picked up directly from APPLICATION_CONFIG_DIR, then look no further.
          break()
        endif()
      endif()
    endforeach()
    # Construct a list of variables that, when present in the root
    # image, should be passed on to all child images as well.
    list(APPEND
      SHARED_MULTI_IMAGE_VARIABLES
      CMAKE_BUILD_TYPE
      CMAKE_VERBOSE_MAKEFILE
      BOARD_DIR
      BOARD_REVISION
      ZEPHYR_MODULES
      ZEPHYR_EXTRA_MODULES
      ZEPHYR_TOOLCHAIN_VARIANT
      GNUARMEMB_TOOLCHAIN_PATH
      EXTRA_KCONFIG_TARGETS
      NCS_TOOLCHAIN_VERSION
      PM_DOMAINS
      ${ACI_DOMAIN}_PM_DOMAIN_DYNAMIC_PARTITION
      WEST_PYTHON
      )

    # Construct a list of cache variables that, when present in the root
    # image, should be passed on to all child images as well.
    list(APPEND
      SHARED_CACHED_MULTI_IMAGE_VARIABLES
      ARCH_ROOT
      BOARD_ROOT
      SOC_ROOT
      MODULE_EXT_ROOT
      SCA_ROOT
    )

    foreach(kconfig_target ${EXTRA_KCONFIG_TARGETS})
      list(APPEND
        SHARED_MULTI_IMAGE_VARIABLES
        EXTRA_KCONFIG_TARGET_COMMAND_FOR_${kconfig_target}
        )
    endforeach()

    set(preload_file ${CMAKE_BINARY_DIR}/${ACI_NAME}/child_image_preload.cmake)
    file(WRITE ${preload_file} "# Generated file used for preloading a child image\n")

    unset(image_cmake_args)
    list(REMOVE_DUPLICATES SHARED_MULTI_IMAGE_VARIABLES)
    foreach(shared_var ${SHARED_MULTI_IMAGE_VARIABLES})
      if(DEFINED ${shared_var})
        file(
          APPEND
          ${preload_file}
          "set(${shared_var} \"${${shared_var}}\" CACHE INTERNAL \"NCS child image controlled\")\n"
          )
      endif()
    endforeach()

    list(REMOVE_DUPLICATES SHARED_CACHED_MULTI_IMAGE_VARIABLES)
    foreach(shared_var ${SHARED_CACHED_MULTI_IMAGE_VARIABLES})
      if(DEFINED CACHE{${shared_var}} AND NOT DEFINED ${ACI_NAME}_${shared_var})
        file(
          APPEND
          ${preload_file}
          "set(${shared_var} \"$CACHE{${shared_var}}\" CACHE INTERNAL \"NCS child image controlled\")\n"
          )
      endif()
    endforeach()

    # Add FILE_SUFFIX to the preload file if it is set with the specific name of this image
    file(APPEND
         ${preload_file}
         "set(FILE_SUFFIX \"${${ACI_NAME}_FILE_SUFFIX}\" CACHE INTERNAL \"NCS child image controlled\")\n"
         )

    get_cmake_property(VARIABLES              VARIABLES)
    get_cmake_property(VARIABLES_CACHED CACHE_VARIABLES)

    set(regex "^${ACI_NAME}_.+")

    list(FILTER VARIABLES        INCLUDE REGEX ${regex})
    list(FILTER VARIABLES_CACHED INCLUDE REGEX ${regex})

    set(VARIABLES_ALL ${VARIABLES} ${VARIABLES_CACHED})
    list(REMOVE_DUPLICATES VARIABLES_ALL)
    foreach(var_name ${VARIABLES_ALL})
      string(REPLACE "\"" "\\\"" ${var_name} "${${var_name}}")
      # This regex is guaranteed to match due to the filtering done
      # above, we only re-run the regex to extract the part after
      # '_'. We run the regex twice because it is believed that
      # list(FILTER is faster than doing a string(REGEX on each item.
      string(REGEX MATCH "^${ACI_NAME}_(.+)" unused_out_var ${var_name})
      file(
        APPEND
        ${preload_file}
        "set(${CMAKE_MATCH_1} \"${${var_name}}\" CACHE INTERNAL \"NCS child image controlled\")\n"
        )
    endforeach()
  endif()

  file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/${ACI_NAME})
  execute_process(
    COMMAND ${CMAKE_COMMAND}
    -G${CMAKE_GENERATOR}
    ${EXTRA_MULTI_IMAGE_CMAKE_ARGS} # E.g. --trace-expand
    -DIMAGE_NAME=${ACI_NAME}
    -C ${preload_file}
    ${extra_cmake_args}
    ${source_dir}
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/${ACI_NAME}
    RESULT_VARIABLE ret
    )

  if (IMAGE_NAME)
    # Expose your childrens secrets to your parent
    set_shared(FILE ${CMAKE_BINARY_DIR}/${ACI_NAME}/shared_vars.cmake)
  endif()

  set_property(DIRECTORY APPEND PROPERTY
    CMAKE_CONFIGURE_DEPENDS
    ${CMAKE_BINARY_DIR}/${ACI_NAME}/zephyr/.config
    )

  if(NOT ${ret} EQUAL "0")
    message(FATAL_ERROR "CMake generation for ${ACI_NAME} failed, aborting. Command: ${ret}")
  endif()

  message("=== child image ${ACI_NAME} - ${ACI_DOMAIN}${inherited} end ===\n")

  # Include some variables from the child image into the parent image
  # namespace
  include(${CMAKE_BINARY_DIR}/${ACI_NAME}/shared_vars.cmake)

  if(MULTI_IMAGE_DEBUG_MAKEFILE AND "${CMAKE_GENERATOR}" STREQUAL "Ninja")
    set(multi_image_build_args "-d" "${MULTI_IMAGE_DEBUG_MAKEFILE}")
  endif()
  if(MULTI_IMAGE_DEBUG_MAKEFILE AND "${CMAKE_GENERATOR}" STREQUAL "Unix Makefiles")
    set(multi_image_build_args "--debug=${MULTI_IMAGE_DEBUG_MAKEFILE}")
  endif()

  get_shared(${ACI_NAME}_byproducts IMAGE ${ACI_NAME} PROPERTY BUILD_BYPRODUCTS)

  include(ExternalProject)
  ExternalProject_Add(${ACI_NAME}_subimage
    SOURCE_DIR ${source_dir}
    BINARY_DIR ${CMAKE_BINARY_DIR}/${ACI_NAME}
    BUILD_BYPRODUCTS ${${ACI_NAME}_byproducts}
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ${CMAKE_COMMAND} --build . -- ${multi_image_build_args}
    INSTALL_COMMAND ""
    BUILD_ALWAYS True
    USES_TERMINAL_BUILD True
    )

  set_property(
    TARGET ${ACI_NAME}_subimage
    PROPERTY preload_file
    ${preload_file}
    )

  set_property(
    TARGET ${ACI_NAME}_subimage
    PROPERTY source_dir
    ${source_dir}
    )

  set_property(
    TARGET ${ACI_NAME}_subimage
    PROPERTY binary_dir
    ${CMAKE_BINARY_DIR}/${ACI_NAME}
    )

  if (NOT ACI_PRELOAD_IMAGE)
    foreach(kconfig_target
        menuconfig
        guiconfig
        ${EXTRA_KCONFIG_TARGETS}
        )

      add_custom_target(${ACI_NAME}_${kconfig_target}
        ${CMAKE_MAKE_PROGRAM} ${kconfig_target}
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/${ACI_NAME}
        USES_TERMINAL
        )
    endforeach()
  endif()

  if (NOT "${ACI_NAME}" STREQUAL "${${ACI_DOMAIN}_PM_DOMAIN_DYNAMIC_PARTITION}")
    set_property(
      GLOBAL APPEND PROPERTY
      PM_IMAGES
      "${ACI_NAME}"
      )
  endif()

endfunction()
