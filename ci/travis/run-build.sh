#!/bin/bash
set -e

# cd to docker build dir if it exists
if [ -d /docker_build_dir ] ; then
	cd /docker_build_dir
fi

. ./ci/travis/lib.sh

MAIN_BRANCH=${MAIN_BRANCH:-master}

if [ -f "${FULL_BUILD_DIR}/env" ] ; then
	echo_blue "Loading environment variables"
	cat "${FULL_BUILD_DIR}/env"
	. "${FULL_BUILD_DIR}/env"
fi

# Run once for the entire script
sudo apt-get -qq update

apt_install() {
	sudo apt-get install -y $@
}

if [ -z "$NUM_JOBS" ] ; then
	NUM_JOBS=$(getconf _NPROCESSORS_ONLN)
	NUM_JOBS=${NUM_JOBS:-1}
fi

KCFLAGS="-Werror"
# FIXME: remove the line below once Talise & Mykonos APIs
#	 dont't use 1024 bytes on stack
KCFLAGS="$KCFLAGS -Wno-error=frame-larger-than="
export KCFLAGS

# FIXME: remove this function once kernel gets upgrade and
#	 GCC doesn't report these warnings anymore
adjust_kcflags_against_gcc() {
	GCC="${CROSS_COMPILE}gcc"
	if [ "$($GCC -dumpversion | cut -d. -f1)" -ge "8" ]; then
		KCFLAGS="$KCFLAGS -Wno-error=stringop-truncation"
		KCFLAGS="$KCFLAGS -Wno-error=packed-not-aligned"
		KCFLAGS="$KCFLAGS -Wno-error=stringop-overflow= -Wno-error=sizeof-pointer-memaccess"
		KCFLAGS="$KCFLAGS -Wno-error=missing-attributes"
	fi

	if [ "$($GCC -dumpversion | cut -d. -f1)" -ge "9" ]; then
		KCFLAGS="$KCFLAGS -Wno-error=address-of-packed-member -Wno-error=attribute-alias="
		KCFLAGS="$KCFLAGS -Wno-error=stringop-truncation"
	fi
	if [ "$($GCC -dumpversion | cut -d. -f1)" -ge "10" ]; then
		KCFLAGS="$KCFLAGS -Wno-error=maybe-uninitialized -Wno-error=restrict"
		KCFLAGS="$KCFLAGS -Wno-error=zero-length-bounds"
	fi
	export KCFLAGS
}

APT_LIST="make bc u-boot-tools flex bison libssl-dev"

if [ "$ARCH" = "arm64" ] ; then
	if [ -z "$CROSS_COMPILE" ] ; then
		CROSS_COMPILE=aarch64-linux-gnu-
		export CROSS_COMPILE
	fi

	APT_LIST="$APT_LIST gcc-aarch64-linux-gnu"
fi

if [ "$ARCH" = "arm" ] ; then
	if [ -z "$CROSS_COMPILE" ] ; then
		CROSS_COMPILE=arm-linux-gnueabihf-
		export CROSS_COMPILE
	fi

	APT_LIST="$APT_LIST gcc-arm-linux-gnueabihf"
fi

apt_update_install() {
	apt_install $@
	adjust_kcflags_against_gcc
}

__get_all_c_files() {
	git grep -i "$@" | cut -d: -f1 | sort | uniq  | grep "\.c"
}

check_all_adi_files_have_been_built() {
	# Collect all .c files that contain the 'Analog Devices' string/name
	local c_files=$(__get_all_c_files "Analog Devices")
	local ltc_c_files=$(__get_all_c_files "Linear Technology")
	local o_files
	local exceptions_file="ci/travis/${DEFCONFIG}_compile_exceptions"
	local ret=0

	c_files="drivers/misc/mathworks/*.c $c_files $ltc_c_files"

	# Convert them to .o files via sed, and extract only the filenames
	for file in $c_files ; do
		file1=$(echo $file | sed 's/\.c/\.o/g')
		if [ -f "$exceptions_file" ] ; then
			if grep -q "$file1" "$exceptions_file" ; then
				continue
			fi
		fi
		if [ ! -f "$file1" ] ; then
			if [ "$ret" = "0" ] ; then
				echo
				echo_red "The following files need to be built OR"
				echo_green "      added to '$exceptions_file'"

				echo

				echo_green "  If adding the '$exceptions_file', please make sure"
				echo_green "  to check if it's better to add the correct Kconfig symbol"
				echo_green "  to one of the following files:"

				for file in $(find -name Kconfig.adi) ; do
					echo_green "   $file"
				done

				echo
			fi
			echo_red "File '$file1' has not been compiled"
			ret=1
		fi
	done

	return $ret
}

get_ref_branch() {
	if [ -n "$TARGET_BRANCH" ] ; then
		echo -n "$TARGET_BRANCH"
	elif [ -n "$TRAVIS_BRANCH" ] ; then
		echo -n "$TRAVIS_BRANCH"
	elif [ -n "$GITHUB_BASE_REF" ] ; then
		echo -n "$GITHUB_BASE_REF"
	else
		echo -n "HEAD~5"
	fi
}

build_check_is_new_adi_driver_dual_licensed() {
	local ret

	local ref_branch="$(get_ref_branch)"

	if [ -z "$ref_branch" ] ; then
		echo_red "Could not get a base_ref for checkpatch"
		exit 1
	fi

	COMMIT_RANGE="${ref_branch}.."

	echo_green "Running checkpatch for commit range '$COMMIT_RANGE'"

	ret=0
	# Get list of files in the commit range
	for file in $(git diff --name-only "$COMMIT_RANGE") ; do
		if git diff "$COMMIT_RANGE" "$file" | grep -q "+MODULE_LICENSE" ; then
			# Check that it has an 'Analog Devices' string
			if ! grep -q "Analog Devices" "$file" ; then
				continue
			fi
			if git diff "$COMMIT_RANGE" "$file" | grep "+MODULE_LICENSE" | grep -v "Dual" ; then
				echo_red "File '$file' contains new Analog Devices' driver"
				echo_red "New 'Analog Devices' drivers must be dual-licensed, with a license being BSD"
				echo_red " Example: MODULE_LICENSE(Dual BSD/GPL)"
				ret=1
			fi
		fi
	done

	return $ret
}

build_default() {
	[ -n "$DEFCONFIG" ] || {
		echo_red "No DEFCONFIG provided"
		return 1
	}

	[ -n "$ARCH" ] || {
		echo_red "No ARCH provided"
		return 1
	}

	APT_LIST="$APT_LIST git"

	apt_update_install $APT_LIST
	make ${DEFCONFIG}
	make -j$NUM_JOBS $IMAGE UIMAGE_LOADADDR=0x8000

	if [ "$CHECK_ALL_ADI_DRIVERS_HAVE_BEEN_BUILT" = "1" ] ; then
		check_all_adi_files_have_been_built
	fi

	make savedefconfig
	mv defconfig arch/$ARCH/configs/$DEFCONFIG

	git diff --exit-code || {
		echo_red "Defconfig file should be updated: 'arch/$ARCH/configs/$DEFCONFIG'"
		echo_red "Run 'make savedefconfig', overwrite it and commit it"
		return 1
	}
}

build_allmodconfig() {
	APT_LIST="$APT_LIST git"

	apt_update_install $APT_LIST
	make allmodconfig
	make -j$NUM_JOBS
}

build_checkpatch() {
	# TODO: Re-visit periodically:
	# https://github.com/torvalds/linux/blob/master/Documentation/devicetree/writing-schema.rst
	# This seems to change every now-n-then
	apt_install python-ply python-git libyaml-dev python3-pip python3-setuptools
	pip3 install wheel
	pip3 install git+https://github.com/devicetree-org/dt-schema.git@master

	local ref_branch="$(get_ref_branch)"

	echo_green "Running checkpatch for commit range '$ref_branch..'"

	if [ -z "$ref_branch" ] ; then
		echo_red "Could not get a base_ref for checkpatch"
		exit 1
	fi

	__update_git_ref "${ref_branch}" "${ref_branch}"

	scripts/checkpatch.pl --git "${ref_branch}.." \
		--ignore FILE_PATH_CHANGES \
		--ignore LONG_LINE \
		--ignore LONG_LINE_STRING \
		--ignore LONG_LINE_COMMENT
}

build_dtb_build_test() {
	local exceptions_file="ci/travis/dtb_build_test_exceptions"
	local err=0
	local last_arch

	for file in $DTS_FILES; do
		arch=$(echo $file |  cut -d'/' -f2)
		# a bit hard-coding for now; only check arm & arm64 DTs;
		# they are shipped via SD-card
		if [ "$arch" != "arm" ] && [ "$arch" != "arm64" ] ; then
			continue
		fi
		if [ -f "$exceptions_file" ] ; then
			if grep -q "$file" "$exceptions_file" ; then
				continue
			fi
		fi
		if ! grep -q "hdl_project:" $file ; then
			echo_red "'$file' doesn't contain an 'hdl_project:' tag"
			err=1
			hdl_project_tag_err=1
		fi
	done

	for file in $DTS_FILES; do
		dtb_file=$(echo $file | sed 's/dts\//=/g' | cut -d'=' -f2 | sed 's\dts\dtb\g')
		arch=$(echo $file |  cut -d'/' -f2)
		if [ "$last_arch" != "$arch" ] ; then
			ARCH=$arch make defconfig
			last_arch=$arch
		fi
		# XXX: hack for nios2, which doesn't have `arch/nios2/boot/dts/Makefile`
		# but even an empty one is fine
		if [ ! -f arch/$arch/boot/dts/Makefile ] ; then
			touch arch/$arch/boot/dts/Makefile
		fi
		ARCH=$arch make ${dtb_file} -j$NUM_JOBS || err=1
	done

	if [ "$err" = "0" ] ; then
		echo_green "DTB build tests passed"
		return 0
	fi

	if [ "$hdl_project_tag_err" = "1" ] ; then
		echo
		echo
		echo_green "Some DTs have been found that do not contain an 'hdl_project:' tag"
		echo_green "   Either:"
		echo_green "     1. Create a 'hdl_project' tag for it"
		echo_green "     OR"
		echo_green "     1. add it in file '$exceptions_file'"
	fi

	return $err
}

branch_contains_commit() {
	local commit="$1"
	local branch="$2"
	git merge-base --is-ancestor $commit $branch &> /dev/null
}

__update_git_ref() {
	local ref="$1"
	local local_ref="$2"
	local depth
	[ "$GIT_FETCH_DEPTH" = "disabled" ] || {
		depth="--depth=${GIT_FETCH_DEPTH:-50}"
	}
	if [ -n "$local_ref" ] ; then
		git fetch $depth $ORIGIN +refs/heads/${ref}:${local_ref}
	else
		git fetch $depth $ORIGIN +refs/heads/${ref}
	fi
}

__push_back_to_github() {
	local dst_branch="$1"

	git push --quiet -u $ORIGIN "HEAD:$dst_branch" || {
		echo_red "Failed to push back '$dst_branch'"
		return 1
	}
}

__handle_sync_with_main() {
	local dst_branch="$1"
	local method="$2"

	__update_git_ref "$dst_branch" || {
		echo_red "Could not fetch branch '$dst_branch'"
		return 1
	}

	if [ "$method" = "fast-forward" ] ; then
		git checkout FETCH_HEAD
		git merge --ff-only ${ORIGIN}/${MAIN_BRANCH} || {
			echo_red "Failed while syncing ${ORIGIN}/${MAIN_BRANCH} over '$dst_branch'"
			return 1
		}
		__push_back_to_github "$dst_branch" || return 1
		return 0
	fi

	if [ "$method" = "cherry-pick" ] ; then
		local depth
		if [ "$GIT_FETCH_DEPTH" = "disabled" ] ; then
			depth=50
		else
			GIT_FETCH_DEPTH=${GIT_FETCH_DEPTH:-50}
			depth=$((GIT_FETCH_DEPTH - 1))
		fi
		# FIXME: kind of dumb, the code below; maybe do this a bit neater
		local cm="$(git log "FETCH_HEAD~${depth}..FETCH_HEAD" | grep "cherry picked from commit" | head -1 | awk '{print $5}' | cut -d')' -f1)"
		[ -n "$cm" ] || {
			echo_red "Top commit in branch '${dst_branch}' is not cherry-picked"
			return 1
		}
		branch_contains_commit "$cm" "${ORIGIN}/${MAIN_BRANCH}" || {
			echo_red "Commit '$cm' is not in branch '${MAIN_BRANCH}'"
			return 1
		}
		# Make sure that we are adding something new, or cherry-pick complains
		if git diff --quiet "$cm" "${ORIGIN}/${MAIN_BRANCH}" ; then
			return 0
		fi

		tmpfile=$(mktemp)

		if [ "$CI" = "true" ] ; then
			# setup an email account so that we can cherry-pick stuff
			git config user.name "CSE CI"
			git config user.email "cse-ci-notifications@analog.com"
		fi

		git checkout FETCH_HEAD
		# cherry-pick until all commits; if we get a merge-commit, handle it
		git cherry-pick -x "${cm}..${ORIGIN}/${MAIN_BRANCH}" 1>/dev/null 2>$tmpfile || {
			was_a_merge=0
			while grep -q "is a merge" $tmpfile ; do
				was_a_merge=1
				# clear file
				cat /dev/null > $tmpfile
				# retry ; we may have a new merge commit
				git cherry-pick --continue 1>/dev/null 2>$tmpfile || {
					was_a_merge=0
					continue
				}
			done
			if [ "$was_a_merge" != "1" ]; then
				echo_red "Failed to cherry-pick commits '$cm..${ORIGIN}/${MAIN_BRANCH}'"
				echo_red "$(cat $tmpfile)"
				return 1
			fi
		}
		__push_back_to_github "$dst_branch" || return 1
		return 0
	fi
}

build_sync_branches_with_main() {
	GIT_FETCH_DEPTH=50
	BRANCHES="xcomm_zynq:fast-forward adi-5.4.0:cherry-pick"
	BRANCHES="$BRANCHES rpi-5.4.y:cherry-pick"

	__update_git_ref "$MAIN_BRANCH" "$MAIN_BRANCH" || {
		echo_red "Could not fetch branch '$MAIN_BRANCH'"
		return 1
	}

	for branch in $BRANCHES ; do
		local dst_branch="$(echo $branch | cut -d: -f1)"
		[ -n "$dst_branch" ] || break
		local method="$(echo $branch | cut -d: -f2)"
		[ -n "$method" ] || break
		__handle_sync_with_main "$dst_branch" "$method"
	done
}

ORIGIN=${ORIGIN:-origin}

BUILD_TYPE=${BUILD_TYPE:-${1}}
BUILD_TYPE=${BUILD_TYPE:-default}

build_${BUILD_TYPE}
